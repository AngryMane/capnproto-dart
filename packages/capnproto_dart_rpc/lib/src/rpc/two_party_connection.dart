import 'dart:async';
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
        capabilityFromResult,
        requireCapabilityFromResult;
import '../capability/capability_factory.dart';
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

  // Exports: capabilities we have sent to the peer.
  // Key = export ID; value tracks the remote reference count so we know
  // when the peer has released all references and we can dispose the cap.
  final Map<int, _ExportEntry> _exports = {};
  // Reverse map: capability object → its export ID (for dedup on re-export).
  final Map<Capability, int> _exportIds = {};
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
  ) {
    _runMessageLoop(incoming);
  }

  /// Creates a client-side connection.
  factory TwoPartyRpcConnection.client({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
  }) => TwoPartyRpcConnection._(incoming, outgoing, true);

  /// Creates a server-side connection.
  factory TwoPartyRpcConnection.server({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
    required Capability bootstrap,
  }) {
    final conn = TwoPartyRpcConnection._(incoming, outgoing, false);
    // Register bootstrap as export 0.
    conn._exports[0] = _ExportEntry(bootstrap);
    conn._exportIds[bootstrap] = 0;
    return conn;
  }

  // ---------------------------------------------------------------------------
  // RpcConnection interface
  // ---------------------------------------------------------------------------

  @override
  T bootstrap<T extends Capability>(CapabilityFactory<T> factory) {
    if (_closedError != null) {
      throw RpcException('connection is closed');
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
    if (_closedError != null) throw RpcException('connection is closed');

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
      throw RpcException(ret.exceptionReason ?? 'remote exception');
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
        final msg = parseRpcMessage(rawBytes);
        _handleIncomingMessage(msg, rawBytes);
      },
      onError: (Object err) => _tearDown(err),
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
        _tearDown(RpcException(msg.exceptionReason ?? 'peer aborted'));
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
    // Server side: send Return with our bootstrap capability (export 0).
    _sendRaw(
      buildBootstrapReturnMessage(answerId: msg.questionId, exportId: 0),
    );
    // Register the bootstrap answer so pipelined calls targeting
    // {receiverAnswer: {questionId: msg.questionId, transform: []}} can
    // resolve ptr[0] → the bootstrap capability.
    final bootstrapCap = _exports[0]?.capability;
    if (bootstrapCap != null) {
      _answerCaps[msg.questionId] =
          _ResolvedAnswer(_bootstrapResultBytes, [bootstrapCap]);
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

    final cancellation = DispatchCancellationController();
    _dispatchCancellations[qid] = cancellation;

    final dispatchFuture = Future.sync(
      () => cap.dispatchWithContext(
        msg.interfaceId,
        msg.methodId,
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
          if (_finishedAnswers.remove(qid)) {
            _answerCaps.remove(qid);
            _answers.remove(qid);
            return;
          }
          _answerCaps[qid] = _ResolvedAnswer(result.bytes, result.caps);

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
          if (_finishedAnswers.remove(qid)) {
            _answers.remove(qid);
            return;
          }
          _answers[qid] = const [];
          _sendRaw(
            buildReturnExceptionMessage(
              answerId: qid,
              reason: err is RpcException ? err.message : err.toString(),
            ),
          );
        });
  }

  void _handleFinish(RpcMessage msg) {
    final qid = msg.questionId;
    _answerCaps.remove(qid);
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
            RpcException(msg.exceptionReason ?? 'bootstrap failed'),
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
    }

    if (!completer.isCompleted) {
      completer.complete(msg);
    }
  }

  void _handleRelease(RpcMessage msg) {
    final entry = _exports[msg.releaseId];
    if (entry == null) return;
    entry.remoteRefCount -= msg.referenceCount;
    if (entry.remoteRefCount <= 0) {
      _exports.remove(msg.releaseId);
      _exportIds.remove(entry.capability);
      _senderPromiseResolves.remove(msg.releaseId);
      entry.capability.dispose().ignore();
    }
  }

  void _handleResolve(RpcMessage msg) {
    if (msg.isResolveException) {
      final state = _imports[msg.promiseId] ?? _importStateForId(msg.promiseId);
      final error = RpcException(
        msg.exceptionReason ?? 'promise resolved to exception',
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
      entry.capability.dispose().ignore();
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
    _outgoing.add(bytes);
  }

  Future<void> _tearDown(Object? error) async {
    if (_closedError != null) return;
    _closedError = error ?? 'closed';

    final err =
        error != null
            ? RpcException(error.toString())
            : const RpcException('connection closed');

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
      entry.capability.dispose().ignore();
    }
    _exports.clear();
    _exportIds.clear();
    _answers.clear();
    _answerCaps.clear();
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
        _closedCompleter.completeError(error);
      } else {
        _closedCompleter.complete();
      }
    }
  }

  /// A future that completes when the connection is closed.
  Future<void> get done => _closedCompleter.future;

  int get debugPendingQuestionCount => _questions.length;
  int get debugPendingQuestionSentCount => _questionSent.length;
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
      throw const RpcException('capability is disposed');
    }
    final state = await _state;
    if (_disposed) {
      throw const RpcException('capability is disposed');
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
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return _ErrorCapCall(const RpcException('capability is disposed'));
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
            throw const RpcException('capability is disposed');
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
      return Future.error(const RpcException('capability is disposed'));
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
      return _ErrorCapCall(const RpcException('capability is disposed'));
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
      throw const RpcException('capability is disposed');
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
