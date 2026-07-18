import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../capability/capability.dart'
    show
        CapCall,
        Capability,
        DeferredCapability,
        DispatchCancellationController,
        DispatchResult,
        NullCapability,
        TailCall,
        capabilityFromResult,
        requireCapabilityFromResult;
import '../capability/capability_factory.dart';
import 'flow_controller.dart';
import 'rpc_exception.dart';
import 'rpc_proto.dart';

/// A Cap'n Proto RPC Level 1 two-party connection.
///
/// Manages the question/answer/export/import tables and drives the message
/// loop over a byte stream pair.
///
/// Usage (client side):
/// ```dart
/// final conn = TwoPartyRpcConnection.client(
///   incoming: socket.incoming,
///   outgoing: socket.outgoing,
/// );
/// final cap = conn.bootstrap(MyClientFactory());
/// ```
///
/// Usage (server side):
/// ```dart
/// final conn = TwoPartyRpcConnection.server(
///   incoming: socket.incoming,
///   outgoing: socket.outgoing,
///   bootstrap: MyServerImpl(),
/// );
/// ```
class TwoPartyRpcConnection implements RpcConnection {
  final StreamSink<Uint8List> _outgoing;
  final bool _isClient;
  final void Function(Object error, StackTrace stackTrace)? _onDisposeError;
  final int _streamWindowSize;
  final Duration? _disembargoTimeout;

  // Exports: capabilities we have sent to the peer.
  // Key = export ID; value tracks the remote reference count so we know
  // when the peer has released all references and we can dispose the cap.
  final Map<int, _ExportEntry> _exports = {};
  // Reverse map: capability object → its export ID (for dedup on re-export).
  final Map<Capability, int> _exportIds = HashMap<Capability, int>.identity();
  // Bootstrap is registered at export ID 0; subsequent exports start at 1.
  int _nextExportId = 1;

  // Questions: outgoing calls waiting for a Return. Key = question ID.
  final Map<int, Completer<RpcMessage>> _questions = {};
  // Completes when the Call message for a given question has been sent on the
  // wire.  Pipelined calls (promisedAnswer target) await this to guarantee
  // their Call arrives AFTER the parent Call.
  final Map<int, Completer<void>> _questionSent = {};
  int _nextQuestionId = 0;

  // Imports: remote capabilities we hold. Key = import ID (= peer's export ID).
  // We track refcounts to know when to send Release.
  final Map<int, int> _importRefCounts = {};
  final Map<int, _ImportState> _imports = {};
  // Imports that the peer has resolved to an exception. Future calls through
  // these promise/import IDs fail locally instead of becoming null capability
  // calls that hide the original failure.
  final Map<int, RpcException> _brokenImports = {};

  // Answers: incoming calls whose Return has been sent.
  // Key = question ID from the peer; value = export IDs included in the Return.
  // Used to release result caps when the peer sends Finish(releaseResultCaps: true).
  final Map<int, List<int>> _answers = {};

  // Promise-pipeline support (server side):
  //   _answerCaps[qid]  — resolved answer for a completed incoming call
  //   _pendingCaps[qid] — future that resolves to the answer when dispatch completes
  // Needed to handle promisedAnswer-targeted calls that arrive while qid is pending.
  // Both store _ResolvedAnswer (result bytes + cap table) so that
  // _handlePipelinedCall can parse the pointer slot to get the correct cap table index.
  final Map<int, _ResolvedAnswer> _answerCaps = {};
  final Map<int, Future<_ResolvedAnswer>> _pendingCaps = {};
  final Map<int, CapnpException> _answerErrors = {};
  // Incoming questions that were finished by the peer before local dispatch
  // completed. Their dispatch result must be dropped instead of returned.
  final Set<int> _finishedAnswers = {};
  final Map<int, DispatchCancellationController> _dispatchCancellations = {};
  final Map<int, Completer<void>> _embargoes = {};
  int _nextEmbargoId = 0;
  final Set<int> _senderPromiseResolves = {};

  // Set to a non-null error once the connection is closed.
  Object? _closedError;
  final Completer<void> _closedCompleter = Completer<void>();

  // The bootstrap capability reference on this connection (client side).
  // Resolved after the Bootstrap exchange completes.
  _ImportedCapability? _bootstrapCap;
  // Completer for the bootstrap handshake.
  Completer<int>? _bootstrapCompleter;
  // Question ID used for the Bootstrap message (so _handleReturn can
  // distinguish the bootstrap return from regular call returns).
  int? _bootstrapQuestionId;

  TwoPartyRpcConnection._(
    Stream<Uint8List> incoming,
    this._outgoing,
    this._isClient,
    this._onDisposeError,
    this._streamWindowSize,
    this._disembargoTimeout,
  ) {
    _runMessageLoop(incoming);
  }

  /// Default value for [TwoPartyRpcConnection.client]/`.server`'s
  /// [disembargoTimeout] parameter — matches this connection's other
  /// defaults in being generous but finite.
  static const Duration defaultDisembargoTimeout = Duration(seconds: 30);

  /// Creates a client-side connection.
  ///
  /// [onDisposeError] is invoked whenever a capability's `dispose()` throws
  /// during internal cleanup (Release handling, re-export, or teardown). A
  /// dispose failure never blocks or fails the surrounding operation — every
  /// other capability still gets disposed — so without this callback such
  /// errors are otherwise invisible.
  ///
  /// [streamWindowSize] sets the flow-control window (in bytes) used by
  /// `-> stream` method calls made through capabilities on this connection —
  /// see [FlowController].
  ///
  /// [disembargoTimeout] bounds how long this vat waits for the peer's
  /// receiverLoopback reply to a Disembargo it sent (see [_handleResolve]).
  /// Without a bound, a peer that never replies leaves the pipelined call
  /// waiting on that embargo blocked forever. Pass `null` to wait
  /// indefinitely (the previous, unbounded behavior).
  factory TwoPartyRpcConnection.client({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
    Duration? disembargoTimeout = defaultDisembargoTimeout,
  }) => TwoPartyRpcConnection._(
    incoming,
    outgoing,
    true,
    onDisposeError,
    streamWindowSize,
    disembargoTimeout,
  );

  /// Creates a server-side connection.
  ///
  /// See [TwoPartyRpcConnection.client] for [onDisposeError],
  /// [streamWindowSize], and [disembargoTimeout].
  factory TwoPartyRpcConnection.server({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
    required Capability bootstrap,
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
    Duration? disembargoTimeout = defaultDisembargoTimeout,
  }) {
    final conn = TwoPartyRpcConnection._(
      incoming,
      outgoing,
      false,
      onDisposeError,
      streamWindowSize,
      disembargoTimeout,
    );
    // Register bootstrap as export 0. Its remoteRefCount starts at 0 (not 1,
    // unlike the _ExportEntry constructor's default for _getOrCreateExportId
    // callers): the entry needs to exist now so _handleCall/_handleBootstrap
    // can route to it, but the peer doesn't actually hold a reference until
    // it sends a Bootstrap request — _handleBootstrap increments this on
    // every one it answers, matching how _getOrCreateExportId increments on
    // every ordinary export vend.
    conn._exports[0] = _ExportEntry(bootstrap)..remoteRefCount = 0;
    conn._exportIds[bootstrap] = 0;
    return conn;
  }

  // ---------------------------------------------------------------------------
  // RpcConnection interface
  // ---------------------------------------------------------------------------

  @override
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory) {
    if (_closedError != null) {
      throw RpcException('connection is closed', kind: ErrorKind.disconnected);
    }
    if (!_isClient) {
      throw RpcException('bootstrap() must be called on the client side');
    }

    // Return the cached capability if the bootstrap exchange already completed
    // or is in progress.  bootstrap() is idempotent per connection.
    if (_bootstrapCap != null) {
      return factory.fromCapability(_bootstrapCap!);
    }

    // Send Bootstrap message.
    final qid = _nextQuestionId++;
    _bootstrapQuestionId = qid;
    _bootstrapCompleter = Completer<int>();
    _questions[qid] = Completer<RpcMessage>();

    _sendRaw(buildBootstrapMessage(qid));

    _bootstrapCap = _ImportedCapability(this, _bootstrapCompleter!.future);
    return factory.fromCapability(_bootstrapCap!);
  }

  @override
  Future<void> close() async {
    if (_closedError != null) return;
    await _tearDown(null);
  }

  // ---------------------------------------------------------------------------
  // Internal: sending a method call through an imported capability
  // ---------------------------------------------------------------------------

  /// Allocates a question ID immediately, then asynchronously builds the
  /// cap-table entries and sends the Call message.  Returns both the question
  /// ID (available synchronously for pipelining) and the result future.
  ///
  /// Use [importIdFuture] for an `importedCap` target; set
  /// [targetPromisedAnswerQid] + [targetPtrIndex] for a `promisedAnswer`
  /// target (wire-level pipelining).
  (int, Future<DispatchResult>) _startCall(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    Uint8List paramsBytes, {
    List<Capability> paramsCapabilities = const [],
    int? targetPromisedAnswerQid,
    int targetPtrIndex = 0,
  }) {
    if (_closedError != null) {
      throw RpcException('connection is closed', kind: ErrorKind.disconnected);
    }

    final qid = _nextQuestionId++;
    final completer = Completer<RpcMessage>();
    _questions[qid] = completer;
    final sentCompleter = Completer<void>();
    sentCompleter.future.ignore();
    _questionSent[qid] = sentCompleter;

    // Build cap table and send the wire message (may need async for cap resolution).
    _buildAndSendCall(
      qid: qid,
      sentCompleter: sentCompleter,
      importIdFuture: importIdFuture,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetPtrIndex: targetPtrIndex,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsBytes: paramsBytes,
      paramsCapabilities: paramsCapabilities,
    ).catchError((Object e, StackTrace st) {
      _questions.remove(qid);
      _questionSent.remove(qid);
      if (!sentCompleter.isCompleted) sentCompleter.completeError(e, st);
      if (!completer.isCompleted) completer.completeError(e, st);
    });

    final resultFuture = _awaitReturn(qid, completer);
    return (qid, resultFuture);
  }

  Future<void> _buildAndSendCall({
    required int qid,
    required Completer<void> sentCompleter,
    required Future<int>? importIdFuture,
    required int? targetPromisedAnswerQid,
    required int targetPtrIndex,
    required int interfaceId,
    required int methodId,
    required Uint8List paramsBytes,
    required List<Capability> paramsCapabilities,
    bool sendResultsToYourself = false,
  }) async {
    // For promisedAnswer targets, wait until the parent Call is on the wire so
    // the server always receives the parent before the pipelined call.
    if (targetPromisedAnswerQid != null) {
      final parentSent = _questionSent[targetPromisedAnswerQid];
      if (parentSent != null) await parentSent.future;
    }

    // Categorize each capability param:
    //   - Imported cap from this same peer → receiverHosted
    //   - Everything else → senderHosted export
    final capEntries = <RpcCapDescriptor>[];
    for (final cap in paramsCapabilities) {
      if (cap is _ImportedCapability && cap._conn == this) {
        final id = await cap._importIdFuture;
        _throwIfImportBroken(id);
        capEntries.add(RpcCapDescriptor.receiverHosted(id));
      } else if (cap is _WirePipelinedCapability &&
          cap._conn == this &&
          !cap._hasResolved) {
        capEntries.add(
          RpcCapDescriptor.receiverAnswer(cap._parentQid, cap._ptrIndex),
        );
      } else {
        capEntries.add(
          RpcCapDescriptor.senderHosted(_getOrCreateExportId(cap)),
        );
      }
    }

    if (targetPromisedAnswerQid != null) {
      _sendRaw(
        buildCallMessage(
          questionId: qid,
          targetPromisedAnswerQid: targetPromisedAnswerQid,
          targetPtrIndex: targetPtrIndex,
          interfaceId: interfaceId,
          methodId: methodId,
          paramsBytes: paramsBytes,
          capTableDescriptors: capEntries,
          sendResultsToYourself: sendResultsToYourself,
        ),
      );
    } else {
      final importId = await importIdFuture!;
      _throwIfImportBroken(importId);
      _sendRaw(
        buildCallMessage(
          questionId: qid,
          targetImportId: importId,
          interfaceId: interfaceId,
          methodId: methodId,
          paramsBytes: paramsBytes,
          capTableDescriptors: capEntries,
          sendResultsToYourself: sendResultsToYourself,
        ),
      );
    }

    // Signal to any pipelined calls waiting on this question.
    if (!sentCompleter.isCompleted) sentCompleter.complete();
    _questionSent.remove(qid);
  }

  Future<DispatchResult> _awaitReturn(
    int qid,
    Completer<RpcMessage> completer,
  ) async {
    final ret = await completer.future;
    _sendRaw(buildFinishMessage(qid, releaseResultCaps: false));

    if (ret.isReturnException) {
      throw RpcException(
        ret.exceptionReason ?? 'remote exception',
        kind: ret.exceptionKind,
      );
    }
    if (ret.isReturnTakeFromOtherQuestion) {
      // The peer tail-called this call onward to a capability it imports
      // from us — i.e. back to a capability WE host. The real answer is
      // therefore already tracked, locally, under our own incoming-answer
      // bookkeeping for that forwarded call: no extra wire round trip
      // needed to fetch it.
      final resolved = await _resolveLocalAnswer(ret.takeFromOtherQuestion);
      return DispatchResult(bytes: resolved.resultBytes, caps: resolved.caps);
    }
    if (!ret.isReturnResults) {
      // canceled / resultsSentElsewhere / acceptFromThirdParty — none of
      // these are implemented by this vat. Surfacing them as an explicit
      // error is important specifically for resultsSentElsewhere: it's only
      // ever valid as the Return to a call *we* sent with
      // sendResultsTo=yourself (see _sendTailForwardCall, which never routes
      // through _awaitReturn), so seeing it here means a peer sent it
      // unprompted — treating it as an empty success would silently hand
      // the caller a bogus empty-struct result instead of the real one.
      throw RpcException(
        'unsupported Return variant: ${describeReturnDisc(ret.returnDisc)}',
      );
    }

    // Convert capTable entries into ImportedCapabilities.
    final caps = <Capability>[];
    for (final descriptor in ret.capTableDescriptors) {
      caps.add(_capabilityFromDescriptor(descriptor));
    }

    return DispatchResult(
      bytes: ret.resultsBytes ?? _emptyResultBytes,
      caps: caps,
    );
  }

  /// Resolves [qid] against this vat's own incoming-answer bookkeeping, for
  /// correlating a `Return.takeFromOtherQuestion` from the peer.
  ///
  /// Mirrors the `_answerCaps`-then-`_pendingCaps` lookup order
  /// [_handlePipelinedCall] already uses, with one extra case: failed
  /// answers are retained until Finish so a `takeFromOtherQuestion` that
  /// races with the failure still observes the original server exception
  /// rather than a misleading "unknown question id".
  Future<_ResolvedAnswer> _resolveLocalAnswer(int qid) {
    final resolved = _answerCaps[qid];
    if (resolved != null) return Future.value(resolved);
    final pending = _pendingCaps[qid];
    if (pending != null) return pending;
    final error = _answerErrors[qid];
    if (error != null) throw error;
    throw RpcException(
      'takeFromOtherQuestion referenced unknown question id $qid',
    );
  }

  // 24-byte message: struct with 0 data words, 1 pointer word = CapabilityPointer(0).
  // Used as the synthesised result for Bootstrap answers so that pipelined
  // calls targeting {receiverAnswer: {questionId: <boot>, transform: []}}
  // can resolve ptr[0] → _answerCaps[<boot>].caps[0].
  // hi = (dataWords & 0xFFFF) | (ptrWords << 16)
  // For dataWords=0, ptrWords=1: hi = 0x00010000 → LE bytes [0,0,1,0]
  static final _bootstrapResultBytes = Uint8List.fromList([
    0, 0, 0, 0, 2, 0, 0, 0, // header: 1 segment, 2 words
    0, 0, 0, 0, 0, 0, 1, 0, // struct ptr: offset=0, data=0, ptrs=1
    3, 0, 0, 0, 0, 0, 0, 0, // ptr[0] = CapabilityPointer(index=0)
  ]);

  // Pre-built 16-byte message: single segment (1 word), null root pointer.
  // Used as fallback for `-> stream` and void methods that return no content.
  static final _emptyResultBytes = Uint8List.fromList([
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);

  Future<void> _releaseImport(int importId) async {
    final count = _importRefCounts[importId];
    if (count == null || count <= 0) return;
    if (count == 1) {
      _importRefCounts.remove(importId);
      _brokenImports.remove(importId);
      _imports.remove(importId);
    } else {
      _importRefCounts[importId] = count - 1;
    }
    _sendRaw(buildReleaseMessage(importId, 1));
  }

  // ---------------------------------------------------------------------------
  // Internal: message loop
  // ---------------------------------------------------------------------------

  void _runMessageLoop(Stream<Uint8List> incoming) {
    // Use raw-bytes stream so the Unimplemented handler can echo the original.
    MessageStream.deserializeStreamRaw(incoming).listen(
      (rawBytes) {
        // Wrap in try/catch: parseRpcMessage() or _handleIncomingMessage() can
        // throw synchronously (e.g. malformed message). A synchronous throw from
        // an onData callback bypasses onError and becomes an uncaught Zone
        // exception, leaving _tearDown() uncalled and all state unreleased.
        try {
          final msg = parseRpcMessage(rawBytes);
          _handleIncomingMessage(msg, rawBytes);
        } catch (error, stackTrace) {
          _tearDown(
            RpcException('invalid incoming RPC message: $error'),
            stackTrace: stackTrace,
          );
        }
      },
      onError:
          (Object error, StackTrace stackTrace) =>
              _tearDown(error, stackTrace: stackTrace),
      onDone: () => _tearDown(null),
    );
  }

  void _handleIncomingMessage(RpcMessage msg, Uint8List rawBytes) {
    if (_closedError != null) return;

    switch (msg.type) {
      case RpcMessageType.bootstrap:
        _handleBootstrap(msg);
      case RpcMessageType.call:
        _handleCall(msg);
      case RpcMessageType.return_:
        _handleReturn(msg);
      case RpcMessageType.resolve:
        _handleResolve(msg);
      case RpcMessageType.finish:
        _handleFinish(msg);
      case RpcMessageType.release:
        _handleRelease(msg);
      case RpcMessageType.disembargo:
        _handleDisembargo(msg);
      case RpcMessageType.abort:
        _tearDown(
          RpcException(
            msg.exceptionReason ?? 'peer aborted',
            kind: msg.exceptionKind,
          ),
        );
      case RpcMessageType.unimplemented:
        // The peer couldn't handle a message we sent; no action needed.
        break;
      case RpcMessageType.other:
        // Unknown message type: echo it back as Unimplemented so the peer
        // knows we didn't handle it, rather than silently dropping it.
        _sendRaw(buildUnimplementedMessage(rawBytes));
    }
  }

  void _handleBootstrap(RpcMessage msg) {
    if (_rejectDuplicateQuestionId(msg.questionId)) return;
    // Server side: send Return with our bootstrap capability (export 0).
    _sendRaw(
      buildBootstrapReturnMessage(answerId: msg.questionId, exportId: 0),
    );
    // Each Bootstrap request hands the peer a new reference to export 0,
    // exactly like _getOrCreateExportId does for capabilities returned from
    // ordinary calls — without this, a peer that bootstraps twice and later
    // disposes just one of the two resulting capabilities would drop this
    // side's refcount to 0 and dispose the capability out from under the
    // peer's other, still-live reference.
    final exportEntry = _exports[0];
    exportEntry?.remoteRefCount++;
    // Register the bootstrap answer so pipelined calls targeting
    // {receiverAnswer: {questionId: msg.questionId, transform: []}} can
    // resolve ptr[0] → the bootstrap capability.
    final bootstrapCap = exportEntry?.capability;
    if (bootstrapCap != null) {
      _answerCaps[msg.questionId] = _ResolvedAnswer(_bootstrapResultBytes, [
        bootstrapCap,
      ]);
    }
  }

  void _handleCall(RpcMessage msg) {
    if (msg.targetIsPromisedAnswer) {
      _handlePipelinedCall(msg);
      return;
    }

    final entry = _exports[msg.targetImportId];
    if (entry == null) {
      _sendRaw(
        buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'unknown export id: ${msg.targetImportId}',
        ),
      );
      return;
    }
    _dispatchToCapability(msg, entry.capability);
  }

  void _handlePipelinedCall(RpcMessage msg) {
    final parentQid = msg.targetPromisedAnswerQid;
    final ptrIndex = msg.targetPtrIndex;

    // Already resolved: dispatch immediately.
    final resolved = _answerCaps[parentQid];
    if (resolved != null) {
      final cap = _capFromPtrIndex(resolved, ptrIndex);
      if (cap == null) {
        _sendRaw(
          buildReturnExceptionMessage(
            answerId: msg.questionId,
            reason:
                'pointer slot $ptrIndex in result struct is not a capability',
          ),
        );
        return;
      }
      _dispatchToCapability(msg, cap);
      return;
    }

    // Still pending: queue behind the parent dispatch.
    final pending = _pendingCaps[parentQid];
    if (pending == null) {
      _sendRaw(
        buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'unknown promisedAnswer questionId: $parentQid',
        ),
      );
      return;
    }
    pending
        .then((resolved) {
          final cap = _capFromPtrIndex(resolved, ptrIndex);
          if (cap == null) {
            _sendRaw(
              buildReturnExceptionMessage(
                answerId: msg.questionId,
                reason:
                    'pointer slot $ptrIndex in result struct is not a capability',
              ),
            );
            return;
          }
          _dispatchToCapability(msg, cap);
        })
        .catchError((Object err) {
          _sendRaw(
            buildReturnExceptionMessage(
              answerId: msg.questionId,
              reason: 'parent call failed: $err',
            ),
          );
        });
  }

  Capability? _capFromPtrIndex(_ResolvedAnswer resolved, int ptrIndex) =>
      capabilityFromResult(
        DispatchResult(bytes: resolved.resultBytes, caps: resolved.caps),
        ptrIndex,
      );

  void _dispatchToCapability(RpcMessage msg, Capability cap) {
    final qid = msg.questionId;
    if (_rejectDuplicateQuestionId(qid)) return;
    final params = msg.paramsBytes ?? _emptyResultBytes;

    // Resolve capabilities from the incoming capTable.
    // Each entry in the list must correspond 1-to-1 with the capTable index,
    // because capability pointers in the params struct reference these indices.
    // Unsupported or unresolvable descriptors get a NullCapability placeholder
    // so subsequent indices remain correct.
    final paramsCapabilities = <Capability>[];
    for (final descriptor in msg.capTableDescriptors) {
      paramsCapabilities.add(_capabilityFromDescriptor(descriptor));
    }

    // sendResultsTo=yourself: the peer is asking us to forward this call's
    // real answer onward ourselves (tail call). We never consult
    // tryTailCall for such a call — that would mean chaining a tail call
    // off another tail call, which isn't supported (see doc/rpc.md) — just
    // dispatch normally and answer with resultsSentElsewhere instead of a
    // real Return once it settles.
    final sendResultsToYourself = msg.sendResultsToDisc == 1;
    if (!sendResultsToYourself) {
      final TailCall? tailCall;
      try {
        tailCall = cap.tryTailCall(
          msg.interfaceId,
          msg.methodId,
          params,
          paramsCapabilities: paramsCapabilities,
        );
      } catch (error) {
        _answers[qid] = const [];
        _sendRaw(
          buildReturnExceptionMessage(
            answerId: qid,
            reason: error is CapnpException ? error.message : error.toString(),
            kind: error is CapnpException ? error.kind : ErrorKind.failed,
          ),
        );
        return;
      }
      if (tailCall != null) {
        _dispatchTailCall(qid, tailCall);
        return;
      }
    }

    _runDispatch(
      qid,
      cap,
      msg.interfaceId,
      msg.methodId,
      params,
      paramsCapabilities,
      sendResultsToYourself: sendResultsToYourself,
    );
  }

  /// Handles a [Capability.tryTailCall] result for the call answered by
  /// [qid]. When [tailCall]'s target is a capability imported from this
  /// same peer connection, applies the Level 1 wire optimization: forwards
  /// a new Call (flagged `sendResultsTo=yourself`) to that peer and answers
  /// [qid] immediately with `takeFromOtherQuestion`, without waiting for the
  /// forwarded call to complete. Otherwise, falls back to a transparent
  /// proxy — dispatching the tail-called method directly and answering
  /// [qid] normally, with no wire-level difference from an ordinary call.
  void _dispatchTailCall(int qid, TailCall tailCall) {
    final target = tailCall.target;
    if (target is _ImportedCapability && target._conn == this) {
      final (forwardQid, sent) = _sendTailForwardCall(target, tailCall);
      // Must wait for the forwarded Call to actually be on the wire before
      // answering qid with takeFromOtherQuestion — otherwise the peer could
      // see the redirect before the call it points at, and fail to
      // correlate it (see _resolveLocalAnswer).
      sent
          .then((_) {
            if (_closedError != null) return;
            _sendRaw(
              buildReturnTakeFromOtherQuestionMessage(
                answerId: qid,
                questionId: forwardQid,
              ),
            );
            // Nothing was exported directly for this answer — the real
            // result (and any capabilities in it) live under forwardQid's
            // own answer bookkeeping, released independently when the peer
            // finishes that call. Pipelining further off qid itself is not
            // supported: a pipelined call targeting qid will fail with
            // "unknown promisedAnswer questionId", since
            // _answerCaps[qid]/_pendingCaps[qid] are deliberately never
            // populated here.
            _answers[qid] = const [];
          })
          .catchError((Object err) {
            if (_closedError != null) return;
            _answers[qid] = const [];
            _sendRaw(
              buildReturnExceptionMessage(
                answerId: qid,
                reason: err is RpcException ? err.message : err.toString(),
              ),
            );
          });
      return;
    }
    // Not a same-connection import: no wire optimization possible, just
    // dispatch the tail-called method directly and answer qid normally.
    _runDispatch(
      qid,
      target,
      tailCall.interfaceId,
      tailCall.methodId,
      tailCall.paramsBytes,
      tailCall.paramsCapabilities,
    );
  }

  /// Sends a forwarded Call (flagged `sendResultsTo=yourself`) to [target]'s
  /// peer, as part of applying the tail-call wire optimization in
  /// [_dispatchTailCall]. Returns `(questionId, sent)`, where [sent]
  /// completes once the Call has actually been written to the outgoing
  /// sink — callers must wait for it before answering the original call
  /// with takeFromOtherQuestion, so the peer never observes the redirect
  /// before the call it references.
  ///
  /// The forwarded call's actual outcome is irrelevant to this vat — it's
  /// delivered to whichever of this vat's own outgoing calls the peer
  /// correlates via `takeFromOtherQuestion` (see [_resolveLocalAnswer]),
  /// not to us. This just needs to send Finish once any Return arrives, so
  /// it talks to the wire directly rather than going through
  /// [_startCall]/[_awaitReturn] (which expects a real result).
  (int, Future<void>) _sendTailForwardCall(
    _ImportedCapability target,
    TailCall tailCall,
  ) {
    final qid = _nextQuestionId++;
    final completer = Completer<RpcMessage>();
    _questions[qid] = completer;
    final sentCompleter = Completer<void>();
    _questionSent[qid] = sentCompleter;

    _buildAndSendCall(
      qid: qid,
      sentCompleter: sentCompleter,
      importIdFuture: target._importIdFuture,
      targetPromisedAnswerQid: null,
      targetPtrIndex: 0,
      interfaceId: tailCall.interfaceId,
      methodId: tailCall.methodId,
      paramsBytes: tailCall.paramsBytes,
      paramsCapabilities: tailCall.paramsCapabilities,
      sendResultsToYourself: true,
    ).catchError((Object e, StackTrace st) {
      _questions.remove(qid);
      _questionSent.remove(qid);
      if (!sentCompleter.isCompleted) sentCompleter.completeError(e, st);
      if (!completer.isCompleted) completer.completeError(e, st);
    });

    completer.future
        .then(
          (_) => _sendRaw(buildFinishMessage(qid, releaseResultCaps: false)),
        )
        .ignore();

    return (qid, sentCompleter.future);
  }

  /// Runs [cap]'s dispatch for [interfaceId]/[methodId] and answers [qid]
  /// once it settles. This is [_dispatchToCapability]'s original body,
  /// generalized so it also serves [_dispatchTailCall]'s fallback path and
  /// calls received with `sendResultsTo=yourself` — [sendResultsToYourself]
  /// only changes which kind of Return is sent on completion.
  void _runDispatch(
    int qid,
    Capability cap,
    int interfaceId,
    int methodId,
    Uint8List params,
    List<Capability> paramsCapabilities, {
    bool sendResultsToYourself = false,
  }) {
    final cancellation = DispatchCancellationController();
    _dispatchCancellations[qid] = cancellation;

    final dispatchFuture = Future.sync(
      () => cap.dispatchWithContext(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
        context: cancellation.context,
      ),
    );

    // Track the resolved-answer future so pipelined calls can queue behind it.
    // Attach .ignore() to prevent unhandled-rejection if dispatch throws —
    // pipelined callers handle the error via their own catchError.
    final resolvedFuture = dispatchFuture.then(
      (r) => _ResolvedAnswer(r.bytes, r.caps),
    );
    resolvedFuture.ignore();
    _pendingCaps[qid] = resolvedFuture;

    dispatchFuture
        .then((result) {
          _pendingCaps.remove(qid);
          _dispatchCancellations.remove(qid);
          // The connection was torn down while this dispatch was still
          // running. _tearDown() already cleared the answer tables; don't
          // resurrect an entry for a peer that's no longer there. _sendRaw()
          // below would silently no-op anyway, but skip the bookkeeping too
          // so nothing lingers for a caller to observe as a leak. The result
          // is never sent as a Return, so any capabilities it carries would
          // otherwise never be disposed — dispose them here instead.
          if (_closedError != null) {
            _disposeResultCapabilities(result);
            return;
          }
          if (_finishedAnswers.remove(qid)) {
            _answerCaps.remove(qid);
            _answerErrors.remove(qid);
            _answers.remove(qid);
            _disposeResultCapabilities(result);
            return;
          }
          _answerCaps[qid] = _ResolvedAnswer(result.bytes, result.caps);

          if (sendResultsToYourself) {
            // Results are consumed locally by whichever of the peer's own
            // outgoing calls receives Return.takeFromOtherQuestion=qid —
            // nothing is put on the wire for this Return.
            // The answer table is a non-owning rendezvous point in this path:
            // `_awaitReturn()` hands the same local capabilities to the
            // original caller as its DispatchResult, and the later Finish for
            // this forwarded question uses releaseResultCaps=false. Therefore
            // Finish must only drop bookkeeping here, not dispose result.caps.
            _sendRaw(buildReturnResultsSentElsewhereMessage(answerId: qid));
            _answers[qid] = const [];
            return;
          }

          final resultDescriptors = <RpcCapDescriptor>[];
          if (result.caps.isEmpty) {
            _sendRaw(
              buildReturnResultsMessage(
                answerId: qid,
                resultsBytes: result.bytes,
              ),
            );
          } else {
            for (final c in result.caps) {
              resultDescriptors.add(_returnCapDescriptor(c));
            }
            _sendRaw(
              buildReturnResultsWithCapDescriptorsMessage(
                answerId: qid,
                resultsBytes: result.bytes,
                descriptors: resultDescriptors,
              ),
            );
          }
          _answers[qid] = [
            for (final d in resultDescriptors)
              if (d.disc == 1 || d.disc == 2) d.id,
          ];
        })
        .catchError((Object err) {
          _pendingCaps.remove(qid);
          _dispatchCancellations.remove(qid);
          _answerCaps.remove(qid);
          // See the matching comment in the success branch above.
          if (_closedError != null) return;
          if (_finishedAnswers.remove(qid)) {
            _answerErrors.remove(qid);
            _answers.remove(qid);
            return;
          }
          final rpcError =
              err is CapnpException
                  ? err
                  : RpcException(err.toString(), kind: ErrorKind.failed);
          _answerErrors[qid] = rpcError;
          _answers[qid] = const [];
          if (sendResultsToYourself) {
            _sendRaw(buildReturnResultsSentElsewhereMessage(answerId: qid));
            return;
          }
          _sendRaw(
            buildReturnExceptionMessage(
              answerId: qid,
              reason: rpcError.message,
              kind: rpcError.kind,
            ),
          );
        });
  }

  void _handleFinish(RpcMessage msg) {
    final qid = msg.questionId;
    _answerCaps.remove(qid);
    _answerErrors.remove(qid);
    final resultExportIds = _answers.remove(qid);
    if (resultExportIds == null) {
      if (_pendingCaps.containsKey(qid)) {
        _finishedAnswers.add(qid);
        _dispatchCancellations.remove(qid)?.cancel();
      }
      return;
    }
    _finishedAnswers.remove(qid);
    if (!msg.releaseResultCaps) return;
    for (final eid in resultExportIds) {
      _releaseExport(eid);
    }
  }

  void _handleReturn(RpcMessage msg) {
    final completer = _questions.remove(msg.answerId);
    if (completer == null) return;

    // Only drive the bootstrap completer for the bootstrap question itself.
    if (msg.answerId == _bootstrapQuestionId) {
      final bootstrapQid = _bootstrapQuestionId!;
      _bootstrapQuestionId = null;
      if (msg.isReturnResults && msg.capTableEntries.isNotEmpty) {
        final importId = _importIdFromDescriptor(msg.capTableDescriptors.first);
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          if (importId == null) {
            _bootstrapCompleter!.completeError(
              const RpcException(
                'bootstrap Return cap table entry was not an import',
              ),
            );
          } else {
            _bootstrapCompleter!.complete(importId);
          }
        }
      } else if (msg.isReturnException) {
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          _bootstrapCompleter!.completeError(
            RpcException(
              msg.exceptionReason ?? 'bootstrap failed',
              kind: msg.exceptionKind,
            ),
          );
        }
      } else {
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          _bootstrapCompleter!.completeError(
            const RpcException(
              'bootstrap Return had no capability in cap table',
            ),
          );
        }
      }
      // Send Finish to release the server's answer state for this Bootstrap
      // question. releaseResultCaps=false because the client is retaining the
      // imported bootstrap capability.
      _sendRaw(buildFinishMessage(bootstrapQid, releaseResultCaps: false));
    }

    if (!completer.isCompleted) {
      completer.complete(msg);
    }
  }

  void _handleRelease(RpcMessage msg) {
    final entry = _exports[msg.releaseId];
    if (entry == null) return;
    // Releasing zero references is meaningless — a legitimate peer never
    // sends one — and silently accepting it would be a no-op that masks the
    // same kind of peer bug the excessive-count check below guards against.
    if (msg.referenceCount <= 0) {
      _tearDown(
        RpcException(
          'protocol violation: Release(id=${msg.releaseId}) referenceCount '
          'must be positive, got ${msg.referenceCount}',
        ),
      );
      return;
    }
    // A peer can only release references it actually holds. Silently
    // clamping an excessive referenceCount to zero would mask a peer/local
    // refcount mismatch — treat it as a protocol violation instead, since a
    // legitimate peer implementation never sends one.
    if (msg.referenceCount > entry.remoteRefCount) {
      _tearDown(
        RpcException(
          'protocol violation: Release(id=${msg.releaseId}) referenceCount '
          '${msg.referenceCount} exceeds outstanding remote reference count '
          '${entry.remoteRefCount}',
        ),
      );
      return;
    }
    entry.remoteRefCount -= msg.referenceCount;
    if (entry.remoteRefCount <= 0) {
      _exports.remove(msg.releaseId);
      _exportIds.remove(entry.capability);
      _senderPromiseResolves.remove(msg.releaseId);
      _disposeIgnoringErrors(entry.capability);
    }
  }

  void _handleResolve(RpcMessage msg) {
    if (msg.isResolveException) {
      // Mirror the success branch below: if we've already fully released
      // this import (removed from _importRefCounts), a Resolve that arrives
      // late must not resurrect tracking state for it — _importStateForId
      // would otherwise create a brand new _ImportState/_brokenImports
      // entry that nothing will ever clean up.
      if (!_importRefCounts.containsKey(msg.promiseId)) return;
      final state = _imports[msg.promiseId] ?? _importStateForId(msg.promiseId);
      final error = RpcException(
        msg.exceptionReason ?? 'promise resolved to exception',
        kind: msg.exceptionKind,
      );
      _brokenImports[msg.promiseId] = error;
      state.resolveError(error);
      return;
    }

    final descriptor = msg.resolveCapDescriptor;
    if (descriptor == null) return;
    if (!_importRefCounts.containsKey(msg.promiseId)) {
      if (descriptor.disc == 1 || descriptor.disc == 2) {
        _sendRaw(buildReleaseMessage(descriptor.id, 1));
      }
      return;
    }

    final state = _imports[msg.promiseId] ?? _importStateForId(msg.promiseId);
    final replacement = _capabilityFromDescriptor(descriptor);
    if (state.receivedCall && _isLocalCapability(replacement)) {
      final embargoId = _nextEmbargoId++;
      final completer = Completer<void>();
      _embargoes[embargoId] = completer;
      final timeout = _disembargoTimeout;
      if (timeout != null) {
        Timer(timeout, () {
          // Already resolved by the peer's receiverLoopback reply (or by
          // teardown, which clears _embargoes outright) — nothing to do.
          if (_embargoes.remove(embargoId) != completer) return;
          if (!completer.isCompleted) {
            completer.completeError(
              RpcException(
                'Disembargo(id=$embargoId) timed out waiting for the peer\'s '
                'receiverLoopback reply after $timeout',
                kind: ErrorKind.overloaded,
              ),
            );
          }
        });
      }
      _sendRaw(
        buildDisembargoMessage(
          targetImportId: msg.promiseId,
          contextDisc: 0,
          contextId: embargoId,
        ),
      );
      state.resolveCapability(
        DeferredCapability(completer.future.then((_) => replacement)),
      );
    } else {
      state.resolveCapability(replacement);
    }
  }

  void _handleDisembargo(RpcMessage msg) {
    if (msg.disembargoContextDisc == 1) {
      final embargo = _embargoes.remove(msg.disembargoContextId);
      if (embargo != null && !embargo.isCompleted) {
        embargo.complete();
      }
      return;
    }

    // For Level 1 loopback disembargo, senderLoopback is answered with a
    // receiverLoopback carrying the same target and embargo id. Higher-level
    // accept/provide contexts are Level 3/4 and are intentionally ignored.
    if (msg.disembargoContextDisc != 0) return;
    _sendRaw(
      buildDisembargoMessage(
        targetImportId: msg.disembargoTargetImportId,
        targetPromisedAnswerQid:
            msg.disembargoTargetIsPromisedAnswer
                ? msg.disembargoTargetPromisedAnswerQid
                : null,
        targetPtrIndex: msg.disembargoTargetPtrIndex,
        contextDisc: 1,
        contextId: msg.disembargoContextId,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// If [qid] already has tracked answer-lifecycle state (from Bootstrap or
  /// an in-flight/finished Call), tears the connection down as a protocol
  /// violation and returns true. A well-behaved peer never reuses a question
  /// ID before it has fully settled (Finish sent and Return received) — if
  /// it does anyway, registering the new dispatch would silently clobber
  /// _dispatchCancellations/_pendingCaps/_answerCaps for the still-live one,
  /// corrupting cancellation and Return/Finish bookkeeping for both.
  bool _rejectDuplicateQuestionId(int qid) {
    final inUse =
        _pendingCaps.containsKey(qid) ||
        _answerCaps.containsKey(qid) ||
        _answers.containsKey(qid) ||
        _finishedAnswers.contains(qid);
    if (!inUse) return false;
    _tearDown(
      RpcException('protocol violation: duplicate incoming question ID $qid'),
    );
    return true;
  }

  /// Returns the existing export ID for [cap] (incrementing its remote ref
  /// count), or allocates a new export ID if this is the first export.
  int _getOrCreateExportId(Capability cap) {
    final existing = _exportIds[cap];
    if (existing != null) {
      _exports[existing]!.remoteRefCount++;
      return existing;
    }
    final eid = _nextExportId++;
    _exports[eid] = _ExportEntry(cap);
    _exportIds[cap] = eid;
    return eid;
  }

  RpcCapDescriptor _returnCapDescriptor(Capability cap) {
    if (cap is DeferredCapability) {
      final promiseId = _getOrCreateExportId(cap);
      _scheduleSenderPromiseResolve(promiseId, cap);
      return RpcCapDescriptor.senderPromise(promiseId);
    }
    return RpcCapDescriptor.senderHosted(_getOrCreateExportId(cap));
  }

  void _scheduleSenderPromiseResolve(
    int promiseId,
    DeferredCapability promise,
  ) {
    if (!_senderPromiseResolves.add(promiseId)) return;

    promise.resolution
        .then(
          (resolved) async {
            _senderPromiseResolves.remove(promiseId);
            if (!_isStillExportedPromise(promiseId, promise)) return;

            final RpcCapDescriptor descriptor;
            try {
              descriptor = await _resolveDescriptorForCapability(resolved);
            } catch (error) {
              if (!_isStillExportedPromise(promiseId, promise)) return;
              _sendRaw(
                buildResolveExceptionMessage(
                  promiseId: promiseId,
                  reason:
                      error is RpcException ? error.message : error.toString(),
                ),
              );
              return;
            }
            if (!_isStillExportedPromise(promiseId, promise)) {
              if (descriptor.disc == 1 || descriptor.disc == 2) {
                _releaseExport(descriptor.id);
              }
              return;
            }

            _sendRaw(
              buildResolveCapMessage(
                promiseId: promiseId,
                capDisc: descriptor.disc,
                capId: descriptor.id,
              ),
            );
          },
          onError: (Object error) {
            _senderPromiseResolves.remove(promiseId);
            if (!_isStillExportedPromise(promiseId, promise)) return;
            _sendRaw(
              buildResolveExceptionMessage(
                promiseId: promiseId,
                reason:
                    error is RpcException ? error.message : error.toString(),
              ),
            );
          },
        )
        .ignore();
  }

  bool _isStillExportedPromise(int promiseId, DeferredCapability promise) {
    final entry = _exports[promiseId];
    return entry != null && identical(entry.capability, promise);
  }

  Future<RpcCapDescriptor> _resolveDescriptorForCapability(
    Capability cap,
  ) async {
    if (cap is _ImportedCapability && cap._conn == this) {
      final id = await cap._importIdFuture;
      _throwIfImportBroken(id);
      return RpcCapDescriptor.receiverHosted(id);
    }
    if (cap is DeferredCapability) {
      final nestedPromiseId = _getOrCreateExportId(cap);
      _scheduleSenderPromiseResolve(nestedPromiseId, cap);
      return RpcCapDescriptor.senderPromise(nestedPromiseId);
    }
    return RpcCapDescriptor.senderHosted(_getOrCreateExportId(cap));
  }

  /// Decrements the remote ref count for [eid] and disposes the capability
  /// if no remote references remain.
  void _releaseExport(int eid) {
    final entry = _exports[eid];
    if (entry == null) return;
    entry.remoteRefCount--;
    if (entry.remoteRefCount <= 0) {
      _exports.remove(eid);
      _exportIds.remove(entry.capability);
      _senderPromiseResolves.remove(eid);
      _disposeIgnoringErrors(entry.capability);
    }
  }

  /// Disposes [capability] without awaiting or propagating a failure.
  ///
  /// Used for every internally-triggered dispose (Release handling,
  /// re-export, teardown): one capability's `dispose()` throwing must never
  /// block or fail the rest of that cleanup pass. The error isn't simply
  /// dropped, though — it's routed to [_onDisposeError] so callers who care
  /// can observe it instead of it being silently swallowed.
  ///
  /// `Capability.dispose()` is typed `Future<void>` but nothing requires an
  /// implementation to actually be `async` — a synchronously-throwing
  /// override would otherwise throw straight out of this call, aborting
  /// whatever cleanup loop is currently disposing capabilities (teardown's
  /// export walk, a discarded dispatch result's capability list, etc.).
  /// `Future.sync` normalizes both cases into a single rejected future.
  void _disposeIgnoringErrors(Capability capability) {
    Future<void>.sync(capability.dispose).catchError(_reportDisposeError);
  }

  /// Reports a dispose failure via [_onDisposeError], if one was supplied.
  /// Guards against the callback itself throwing, which would otherwise
  /// surface as an unhandled error on this future's cleanup zone instead of
  /// wherever the caller actually observes such things.
  void _reportDisposeError(Object error, StackTrace stackTrace) {
    try {
      _onDisposeError?.call(error, stackTrace);
    } catch (_) {
      // Swallowed deliberately: a misbehaving onDisposeError callback must
      // not break dispose-error reporting for the next capability.
    }
  }

  /// Disposes every capability in a completed dispatch [result] that will
  /// never be sent to the peer as a Return (the connection closed, or a
  /// Finish arrived and canceled this answer before dispatch finished).
  /// Ownership of `result.caps` passes to the RPC runtime the moment the
  /// dispatch future resolves; if the result isn't going out on the wire,
  /// this is the only remaining chance to release those capabilities.
  ///
  /// These capabilities were never exported (that only happens on the send
  /// path we're skipping here), so there's no refcount to fall back on if
  /// the same capability instance appears more than once in `result.caps` —
  /// each distinct instance is disposed exactly once, by identity, rather
  /// than once per occurrence. A dispose failure on one capability doesn't
  /// stop the rest from being disposed.
  void _disposeResultCapabilities(DispatchResult result) {
    final disposed = HashSet<Capability>.identity();
    for (final cap in result.caps) {
      if (disposed.add(cap)) {
        _disposeIgnoringErrors(cap);
      }
    }
  }

  Capability _capabilityFromDescriptor(RpcCapDescriptor descriptor) {
    switch (descriptor.disc) {
      case 1: // senderHosted
        final state = _retainImport(descriptor.id);
        return _ImportedCapability.fromState(this, state);
      case 2: // senderPromise
        final state = _retainImport(descriptor.id, isPromise: true);
        return _ImportedCapability.fromState(this, state);
      case 3: // receiverHosted: we (the receiver) export this cap
        final hosted = _exports[descriptor.id];
        return hosted?.capability ?? NullCapability();
      case 4: // receiverAnswer: capability in one of our outstanding answers
        return _ReceiverAnswerCapability(
          this,
          descriptor.questionId,
          descriptor.ptrIndex,
        );
      default:
        return NullCapability();
    }
  }

  int? _importIdFromDescriptor(RpcCapDescriptor descriptor) {
    if (descriptor.disc != 1 && descriptor.disc != 2) return null;
    _retainImport(descriptor.id, isPromise: descriptor.disc == 2);
    return descriptor.id;
  }

  _ImportState _retainImport(int importId, {bool isPromise = false}) {
    _importRefCounts[importId] = (_importRefCounts[importId] ?? 0) + 1;
    final state = _imports.putIfAbsent(
      importId,
      () => _ImportState(importId, isPromise: isPromise),
    );
    if (isPromise) state.isPromise = true;
    return state;
  }

  _ImportState _importStateForId(int importId) =>
      _imports.putIfAbsent(importId, () => _ImportState(importId));

  bool _isLocalCapability(Capability cap) {
    if (cap is _ImportedCapability && cap._conn == this) return false;
    if (cap is _WirePipelinedCapability && cap._conn == this) return false;
    return true;
  }

  void _throwIfImportBroken(int importId) {
    final err = _brokenImports[importId];
    if (err != null) throw err;
  }

  void _sendRaw(Uint8List bytes) {
    if (_closedError != null) return;
    // StreamSink.add() isn't documented to throw synchronously (failures are
    // normally reported asynchronously via the sink's `done` future), but
    // nothing stops a sink implementation from doing so anyway. Some call
    // sites (e.g. completing a dispatch) run from an async continuation with
    // no enclosing message-loop try/catch, so an uncaught throw here would
    // otherwise surface as an unhandled future rejection instead of a clean
    // teardown.
    try {
      _outgoing.add(bytes);
    } catch (error, stackTrace) {
      _tearDown(error, stackTrace: stackTrace);
    }
  }

  Future<void> _tearDown(Object? error, {StackTrace? stackTrace}) async {
    if (_closedError != null) return;
    _closedError = error ?? 'closed';

    final err =
        error != null
            ? RpcException(
              'connection torn down: $error',
              kind: ErrorKind.disconnected,
              cause: error,
            )
            : const RpcException(
              'connection closed',
              kind: ErrorKind.disconnected,
            );

    // Fail all pending questions.
    for (final c in _questions.values) {
      if (!c.isCompleted) {
        c.future.ignore();
        c.completeError(err);
      }
    }
    _questions.clear();
    for (final c in _questionSent.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _questionSent.clear();

    if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
      _bootstrapCompleter!.future.ignore();
      _bootstrapCompleter!.completeError(err);
    }

    for (final cancellation in _dispatchCancellations.values) {
      cancellation.cancel();
    }
    _dispatchCancellations.clear();

    // Dispose all exported capabilities.
    for (final entry in _exports.values) {
      _disposeIgnoringErrors(entry.capability);
    }
    _exports.clear();
    _exportIds.clear();
    _answers.clear();
    _answerCaps.clear();
    _answerErrors.clear();
    _pendingCaps.clear();
    _finishedAnswers.clear();
    _senderPromiseResolves.clear();
    _importRefCounts.clear();
    _imports.clear();
    _brokenImports.clear();
    for (final embargo in _embargoes.values) {
      if (!embargo.isCompleted) {
        embargo.completeError(err);
      }
    }
    _embargoes.clear();

    try {
      await _outgoing.close();
    } catch (_) {}

    if (!_closedCompleter.isCompleted) {
      if (error != null) {
        // Suppress unhandled-rejection if nobody awaits done.
        _closedCompleter.future.ignore();
        _closedCompleter.completeError(error, stackTrace);
      } else {
        _closedCompleter.complete();
      }
    }
  }

  /// A future that completes when the connection is closed.
  Future<void> get done => _closedCompleter.future;

  int get debugPendingQuestionCount => _questions.length;
  int get debugPendingQuestionSentCount => _questionSent.length;

  /// Number of capabilities currently exported to the peer (i.e. still
  /// holding at least one outstanding remote reference).
  int get debugExportCount => _exports.length;

  /// Number of remote capabilities currently imported from the peer (i.e.
  /// still holding at least one outstanding local reference).
  int get debugImportCount => _imports.length;

  /// Number of imports recorded as broken (their promise resolved to an
  /// exception). Tracked separately from [debugImportCount] because a
  /// broken import can still be observed after the import itself is
  /// released — this should settle back to zero once every import that
  /// ever broke has also been fully released.
  int get debugBrokenImportCount => _brokenImports.length;

  /// Number of incoming calls with some tracked answer-lifecycle state:
  /// dispatch in flight ([_pendingCaps]), a resolved-but-not-yet-finished
  /// answer ([_answerCaps]/[_answers]), or a Finish that arrived before
  /// dispatch completed ([_finishedAnswers]). Zero means every incoming call
  /// this connection has seen has fully settled.
  int get debugAnswerCount =>
      <int>{
        ..._answers.keys,
        ..._answerCaps.keys,
        ..._answerErrors.keys,
        ..._pendingCaps.keys,
        ..._finishedAnswers,
      }.length;

  /// Number of incoming dispatches with a live [DispatchCancellationController]
  /// (i.e. dispatch is still running and could still observe cancellation).
  int get debugCancellationCount => _dispatchCancellations.length;

  /// Number of Disembargo round-trips currently awaiting the peer's
  /// receiverLoopback response.
  int get debugEmbargoCount => _embargoes.length;
}

// ---------------------------------------------------------------------------
// _ExportEntry: tracks a locally-exported capability and its remote ref count
// ---------------------------------------------------------------------------

class _ExportEntry {
  final Capability capability;
  // How many times the peer holds a reference to this export.
  // Incremented on every export (or re-export); decremented on Release.
  int remoteRefCount;
  _ExportEntry(this.capability) : remoteRefCount = 1;
}

class _ImportState {
  final int importId;
  bool isPromise;
  bool receivedCall = false;
  Capability? replacement;
  Object? error;
  StackTrace? stackTrace;

  _ImportState(this.importId, {this.isPromise = false});

  void resolveCapability(Capability cap) {
    if (error != null) return;
    replacement = cap;
  }

  void resolveError(Object err, [StackTrace? st]) {
    error = err;
    stackTrace = st;
  }
}

// ---------------------------------------------------------------------------
// _ImportedCapability: client-side proxy for a remote capability
// ---------------------------------------------------------------------------

class _ImportedCapability extends Capability {
  final TwoPartyRpcConnection _conn;
  bool _disposed = false;

  // Resolves to the import ID once the bootstrap handshake completes.
  final Future<int> _importIdFuture;
  final Future<_ImportState>? _stateFuture;
  _ImportState? _cachedState;

  // Lazily created on the first `-> stream` call through this capability
  // reference, then reused for every subsequent streaming call so the
  // window is shared/accumulated across the whole call sequence — matching
  // capnp-rust, which scopes one FlowController per call target.
  FlowController? _flowController;

  _ImportedCapability(this._conn, this._importIdFuture) : _stateFuture = null {
    // Suppress unhandled rejection if nobody awaits this future before the
    // connection closes (e.g. bootstrap() called then close() immediately).
    _importIdFuture.ignore();
  }

  _ImportedCapability.fromState(this._conn, _ImportState state)
    : _importIdFuture = Future.value(state.importId),
      _stateFuture = Future.value(state),
      _cachedState = state {
    _importIdFuture.ignore();
  }

  Future<_ImportState> get _state async {
    final cached = _cachedState;
    if (cached != null) return cached;
    final stateFuture = _stateFuture;
    if (stateFuture != null) {
      final state = await stateFuture;
      _cachedState = state;
      return state;
    }
    final state = _conn._importStateForId(await _importIdFuture);
    _cachedState = state;
    return state;
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final state = await _state;
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final replacement = state.replacement;
    if (replacement != null) {
      return replacement.dispatch(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
      );
    }
    final error = state.error;
    if (error != null) {
      return Future<DispatchResult>.error(error, state.stackTrace);
    }
    state.receivedCall = true;
    final (_, future) = _conn._startCall(
      Future.value(state.importId),
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
    return future;
  }

  @override
  Future<void> dispatchStreaming(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final state = await _state;
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final replacement = state.replacement;
    if (replacement != null) {
      return replacement.dispatchStreaming(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
      );
    }
    final error = state.error;
    if (error != null) {
      return Future<void>.error(error, state.stackTrace);
    }
    state.receivedCall = true;
    // The call is started (and its Call message sent) immediately either
    // way — the flow controller only ever delays how long the *returned*
    // future takes to resolve, never the send itself, so wire ordering is
    // unaffected by window state.
    final (_, future) = _conn._startCall(
      Future.value(state.importId),
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
    final controller =
        _flowController ??= FlowController(windowSize: _conn._streamWindowSize);
    return controller.send(params.lengthInBytes, future);
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return _ErrorCapCall(
        const RpcException(
          'capability is disposed',
          kind: ErrorKind.disconnected,
        ),
      );
    }
    final cached = _cachedState;
    if (cached != null) {
      final replacement = cached.replacement;
      if (replacement != null) {
        return replacement.beginDispatch(
          interfaceId,
          methodId,
          params,
          paramsCapabilities: paramsCapabilities,
        );
      }
      final error = cached.error;
      if (error != null) {
        return _ErrorCapCall(error, cached.stackTrace);
      }
      cached.receivedCall = true;
      final (qid, future) = _conn._startCall(
        Future.value(cached.importId),
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
      );
      return _WireCapCall(future, _conn, qid);
    }
    final stateFuture = _state;
    final qidCompleter = Completer<int>();
    final result = stateFuture
        .then((state) {
          if (_disposed) {
            throw const RpcException(
              'capability is disposed',
              kind: ErrorKind.disconnected,
            );
          }
          final replacement = state.replacement;
          if (replacement != null) {
            return replacement
                .dispatch(
                  interfaceId,
                  methodId,
                  params,
                  paramsCapabilities: paramsCapabilities,
                )
                .then((r) {
                  if (!qidCompleter.isCompleted) qidCompleter.complete(-1);
                  return r;
                });
          }
          final error = state.error;
          if (error != null) {
            return Future<DispatchResult>.error(error, state.stackTrace);
          }
          state.receivedCall = true;
          final (qid, future) = _conn._startCall(
            Future.value(state.importId),
            interfaceId,
            methodId,
            params,
            paramsCapabilities: paramsCapabilities,
          );
          if (!qidCompleter.isCompleted) qidCompleter.complete(qid);
          return future;
        })
        .then((r) => r);
    result.ignore();
    return _AsyncWireCapCall(result, _conn, qidCompleter.future);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final id = await _importIdFuture.catchError((_) => -1);
    if (id >= 0) await _conn._releaseImport(id);
  }
}

// ---------------------------------------------------------------------------
// _WireCapCall: CapCall backed by a pending question on the wire
// ---------------------------------------------------------------------------

class _WireCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  final TwoPartyRpcConnection _conn;
  final int _qid;

  _WireCapCall(this.result, this._conn, this._qid);

  @override
  Capability pipelineResult(int ptrIndex) =>
      _WirePipelinedCapability(_conn, _qid, ptrIndex, result);
}

class _AsyncWireCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  final TwoPartyRpcConnection _conn;
  final Future<int> _qidFuture;

  _AsyncWireCapCall(this.result, this._conn, this._qidFuture);

  @override
  Capability pipelineResult(int ptrIndex) => DeferredCapability(() async {
    final qid = await _qidFuture;
    if (qid >= 0) {
      return _WirePipelinedCapability(_conn, qid, ptrIndex, result);
    }
    final resolved = await result;
    return requireCapabilityFromResult(resolved, ptrIndex);
  }());
}

// ---------------------------------------------------------------------------
// _WirePipelinedCapability: targets a promisedAnswer on the wire, then
// switches to the resolved imported capability once the parent completes.
// ---------------------------------------------------------------------------

class _WirePipelinedCapability extends Capability {
  final TwoPartyRpcConnection _conn;
  final int _parentQid;
  final int _ptrIndex;
  late final Future<Capability> _resolution;

  // Set once the parent question resolves; null while still pending.
  // After resolution all new calls go directly to this cap (no pipelining).
  Capability? _resolved;
  Object? _resolutionError;
  StackTrace? _resolutionStackTrace;
  bool _disposed = false;
  int _pendingPipelinedCalls = 0;
  Future<void>? _resolvedDisposeFuture;
  bool get _hasResolved => _resolved != null || _resolutionError != null;

  _WirePipelinedCapability(
    this._conn,
    this._parentQid,
    this._ptrIndex,
    Future<DispatchResult> parentResult,
  ) {
    _resolution = parentResult.then(
      (result) => requireCapabilityFromResult(result, _ptrIndex),
    );
    _resolution.ignore();
    _resolution
        .then(
          (resolved) async {
            _resolved = resolved;
            if (_disposed) {
              await _disposeResolvedIfIdle();
            }
          },
          onError: (Object err, StackTrace st) {
            _resolutionError = err;
            _resolutionStackTrace = st;
          },
        )
        .ignore();
  }

  Future<T> _trackPipelinedCall<T>(Future<T> future) {
    _pendingPipelinedCalls++;
    future.whenComplete(() {
      _pendingPipelinedCalls--;
      if (_disposed) {
        _disposeResolvedIfIdle().ignore();
      }
    }).ignore();
    return future;
  }

  Future<void> _disposeResolvedIfIdle() {
    final resolved = _resolved;
    if (!_disposed || resolved == null || _pendingPipelinedCalls > 0) {
      return Future.value();
    }
    return _resolvedDisposeFuture ??= resolved.dispose();
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return Future.error(
        const RpcException(
          'capability is disposed',
          kind: ErrorKind.disconnected,
        ),
      );
    }
    final r = _resolved;
    if (r != null) {
      return r.dispatch(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
      );
    }
    final resolutionError = _resolutionError;
    if (resolutionError != null) {
      return Future.error(resolutionError, _resolutionStackTrace);
    }
    final (_, future) = _conn._startCall(
      null,
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
      targetPromisedAnswerQid: _parentQid,
      targetPtrIndex: _ptrIndex,
    );
    return _trackPipelinedCall(future);
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return _ErrorCapCall(
        const RpcException(
          'capability is disposed',
          kind: ErrorKind.disconnected,
        ),
      );
    }
    final r = _resolved;
    if (r != null) {
      return r.beginDispatch(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
      );
    }
    final resolutionError = _resolutionError;
    if (resolutionError != null) {
      return _ErrorCapCall(resolutionError, _resolutionStackTrace);
    }
    final (qid, future) = _conn._startCall(
      null,
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
      targetPromisedAnswerQid: _parentQid,
      targetPtrIndex: _ptrIndex,
    );
    return _WireCapCall(_trackPipelinedCall(future), _conn, qid);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _disposeResolvedIfIdle();
  }
}

class _ReceiverAnswerCapability extends Capability {
  final TwoPartyRpcConnection _conn;
  final int _questionId;
  final int _ptrIndex;
  bool _disposed = false;

  _ReceiverAnswerCapability(this._conn, this._questionId, this._ptrIndex);

  Future<Capability> _resolve() async {
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final resolved = _conn._answerCaps[_questionId];
    if (resolved != null) {
      return requireCapabilityFromResult(
        DispatchResult(bytes: resolved.resultBytes, caps: resolved.caps),
        _ptrIndex,
      );
    }
    final pending = _conn._pendingCaps[_questionId];
    if (pending == null) {
      throw RpcException('invalid receiverAnswer questionId: $_questionId');
    }
    final answer = await pending;
    return requireCapabilityFromResult(
      DispatchResult(bytes: answer.resultBytes, caps: answer.caps),
      _ptrIndex,
    );
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final cap = await _resolve();
    return cap.dispatch(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    final result = _resolve().then(
      (cap) => cap.dispatch(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
      ),
    );
    result.ignore();
    return _FutureCapCall(result);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}

class _FutureCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;

  _FutureCapCall(this.result);

  @override
  Capability pipelineResult(int ptrIndex) => DeferredCapability(
    result.then((r) => requireCapabilityFromResult(r, ptrIndex)),
  );
}

class _ErrorCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;

  _ErrorCapCall(Object error, [StackTrace? stackTrace])
    : result = Future.error(error, stackTrace) {
    result.ignore();
  }

  @override
  Capability pipelineResult(int ptrIndex) => DeferredCapability(
    result.then((r) => requireCapabilityFromResult(r, ptrIndex)),
  );
}

// ---------------------------------------------------------------------------
// _ResolvedAnswer: result bytes + cap table for a completed server dispatch
// ---------------------------------------------------------------------------

/// Holds the serialized result message and the corresponding cap table for a
/// completed incoming call.  Both are needed by [TwoPartyRpcConnection] to
/// resolve promise-pipelined calls: the result bytes encode which pointer slot
/// maps to which cap table index via a [CapabilityPointer], so the lookup must
/// parse the pointer rather than using the pointer-slot number as a cap table
/// index directly.
class _ResolvedAnswer {
  final Uint8List resultBytes;
  final List<Capability> caps;
  _ResolvedAnswer(this.resultBytes, this.caps);
}

// ---------------------------------------------------------------------------
// RpcConnection abstract interface (declared here to avoid circular imports)
// ---------------------------------------------------------------------------

/// Manages an RPC connection to a remote peer.
abstract class RpcConnection {
  /// Returns a typed capability backed by the peer's bootstrap capability.
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory);

  /// Closes the connection and releases all associated capabilities.
  Future<void> close();
}
