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
        capabilityFromResultPath,
        requireCapabilityFromResult,
        requireCapabilityFromResultPath,
        unwrapVendedCapability,
        vendCapabilityHandle;
import '../capability/capability_factory.dart';
import '../capability/rpc_payload.dart';
import 'answer_table.dart';
import 'embargo_table.dart';
import 'export_table.dart';
import 'flow_controller.dart';
import 'import_table.dart';
import 'question_table.dart';
import 'rpc_connection.dart';
import 'rpc_exception.dart';
import 'rpc_proto.dart';

part 'wire_capabilities.dart';

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
void _validateDisembargoTimeout(Duration? timeout) {
  if (timeout != null && timeout.isNegative) {
    throw ArgumentError.value(
      timeout,
      'disembargoTimeout',
      'must be non-negative or null',
    );
  }
}

class TwoPartyRpcConnection implements RpcConnection {
  final StreamSink<Uint8List> _outgoing;
  final bool _isClient;
  final void Function(Object error, StackTrace stackTrace)? _onDisposeError;
  final int _streamWindowSize;
  final Duration? _disembargoTimeout;
  final bool _preFramed;
  StreamSubscription<Uint8List>? _incomingSubscription;
  StreamSubscription<Uint8List>? _incomingSourceSubscription;
  StreamController<Uint8List>? _decoderInput;

  // Exports: capabilities we have sent to the peer.
  final ExportTable _exportTable = ExportTable();

  // Questions: outgoing calls waiting for a Return.
  final QuestionTable _questionTable = QuestionTable();

  // Imports: remote capabilities we hold. Key = import ID (= peer's export ID).
  final ImportTable _importTable = ImportTable();
  // Batches Release sends: _releaseImport() decrements the local refcount
  // immediately (via ImportTable.releaseAndBatch) but only records the count
  // there, deferring the actual wire send to a microtask. Several dispose()
  // calls issued without an intervening await (e.g. disposing a whole
  // observer list in one synchronous pass, or
  // `Future.wait([...].map((c) => c.dispose()))`) therefore coalesce into a
  // single Release per import ID with referenceCount > 1, instead of one
  // wire message each. Sequential `await`ed dispose() calls are unaffected —
  // each already resumes after the previous flush has run, so every Release
  // still carries referenceCount == 1 as before.
  Future<void>? _releaseFlushFuture;

  // Answers: incoming calls this vat is currently (or has recently)
  // answered — see AnswerTable's own doc comment.
  final AnswerTable _answerTable = AnswerTable();
  final EmbargoTable _embargoTable = EmbargoTable();

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
    this._preFramed,
  ) {
    _runMessageLoop(incoming);
    _outgoing.done
        .then(
          (_) {
            if (_closedError == null) _tearDown(null);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_closedError == null) {
              _tearDown(error, stackTrace: stackTrace);
            }
          },
        )
        .ignore();
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
  ///
  /// [preFramed] declares that [incoming] already delivers exactly one
  /// complete Cap'n Proto message per stream event (true for the WebSocket
  /// transport, where each binary frame is one message) — messages are read
  /// directly off each event instead of being fed through the generic
  /// byte-accumulation deframer. Leave `false` for a raw byte stream (e.g. a
  /// TCP/Unix socket) where message boundaries don't align with event
  /// boundaries and must be reconstructed.
  factory TwoPartyRpcConnection.client({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
    Duration? disembargoTimeout = defaultDisembargoTimeout,
    bool preFramed = false,
  }) {
    _validateDisembargoTimeout(disembargoTimeout);
    return TwoPartyRpcConnection._(
      incoming,
      outgoing,
      true,
      onDisposeError,
      streamWindowSize,
      disembargoTimeout,
      preFramed,
    );
  }

  /// Creates a server-side connection.
  ///
  /// See [TwoPartyRpcConnection.client] for [onDisposeError],
  /// [streamWindowSize], [disembargoTimeout], and [preFramed].
  ///
  /// [bootstrap]'s ownership transfers to this connection: it's disposed
  /// (via its export's own owned reference — see [ExportTable]'s doc
  /// comment) once every remote reference to it has been released and,
  /// failing that, when the connection itself is torn down. Callers must
  /// not separately dispose it themselves.
  factory TwoPartyRpcConnection.server({
    required Stream<Uint8List> incoming,
    required StreamSink<Uint8List> outgoing,
    required Capability bootstrap,
    void Function(Object error, StackTrace stackTrace)? onDisposeError,
    int streamWindowSize = FlowController.defaultWindowSize,
    Duration? disembargoTimeout = defaultDisembargoTimeout,
    bool preFramed = false,
  }) {
    _validateDisembargoTimeout(disembargoTimeout);
    final conn = TwoPartyRpcConnection._(
      incoming,
      outgoing,
      false,
      onDisposeError,
      streamWindowSize,
      disembargoTimeout,
      preFramed,
    );
    // Unwrap first, like every ExportTable.getOrCreate caller — bootstrap
    // is registered as export 0 through the same ExportTable machinery, so
    // its identity must satisfy the same "always unwrapped" invariant those
    // rely on for deduplication (e.g. this same underlying capability being
    // handed back to ExportTable.getOrCreate again later, via a normal
    // export, must dedupe against this entry instead of creating a
    // redundant second export for it).
    final bootstrapIdentity = unwrapVendedCapability(bootstrap);
    // See ExportTable.registerBootstrap's doc comment for why its remote
    // refcount starts at 0, not 1.
    conn._exportTable.registerBootstrap(bootstrapIdentity);
    // bootstrap's ownership transfers to this connection (see doc comment
    // above) — the entry just created its own ownedReference for
    // bootstrapIdentity, so if the caller passed an already-vended handle
    // rather than a bare capability, that handle is now redundant with it
    // and must be released, or its outstanding share of bootstrapIdentity's
    // refcount would never be balanced.
    if (!identical(bootstrap, bootstrapIdentity)) {
      conn._disposeIgnoringErrors(bootstrap);
    }
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
    final question = _questionTable.allocateForBootstrap();
    _bootstrapQuestionId = question.id;
    _bootstrapCompleter = Completer<int>();

    _sendRaw(buildBootstrapMessage(question.id));

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
  /// [targetPromisedAnswerQid] + [targetTransformPath] for a
  /// `promisedAnswer` target (wire-level pipelining) — the full
  /// getPointerField hop sequence into the parent answer, not just a single
  /// index, so a capability nested more than one struct deep is expressible
  /// (see [RpcCapDescriptor.path]).
  (int, Future<DispatchResult>) _startCall(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    Uint8List paramsBytes, {
    List<Capability> paramsCapabilities = const [],
    int? targetPromisedAnswerQid,
    List<int> targetTransformPath = const [],
  }) {
    if (_closedError != null) {
      throw RpcException('connection is closed', kind: ErrorKind.disconnected);
    }

    final question = _questionTable.allocate();
    final qid = question.id;
    final completer = question.returnCompleter!;
    final sentCompleter = question.sentCompleter!;
    sentCompleter.future.ignore();

    // Build cap table and send the wire message (may need async for cap resolution).
    _buildAndSendCall(
      qid: qid,
      sentCompleter: sentCompleter,
      importIdFuture: importIdFuture,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetTransformPath: targetTransformPath,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsBytes: paramsBytes,
      paramsCapabilities: paramsCapabilities,
    ).catchError((Object e, StackTrace st) {
      // _buildAndSendCall only ever completes its Future with an error
      // before _sendRaw has run (nothing after that point in its body can
      // throw) — see _rollbackQuestionParamExports's doc comment — so any
      // params export refs _resolveCapTable already bumped for this qid
      // never actually reached the peer and must be rolled back here.
      final ids = _questionTable.failBeforeSend(question, e, st);
      if (ids != null) _applyReleaseParamCaps(ids);
    });

    final resultFuture = _awaitReturn(qid, completer);
    return (qid, resultFuture);
  }

  /// Synchronous-when-possible fast path shared by [_ImportedCapability]'s
  /// `dispatch`/`dispatchBuilding`: since [importId] is already known
  /// synchronously here (no `Future` to await), this skips
  /// [_startCall]/[_startCallBuilding]'s `Future.value(...)`/`await`
  /// indirection for it — each `await`, even of an already-completed
  /// Future, costs at least one microtask tick. [buildParams] writes params
  /// directly into the outgoing Call, same as [_startCallBuilding]; callers
  /// with pre-built bytes pass `(anyPtr) => anyPtr.setMessageBytes(bytes,
  /// preserveCapabilityPointers: true)` (see [buildCallMessage]'s own
  /// delegation to the *Building variants for the same pattern).
  ///
  /// The capTable is resolved via [_resolveCapTableMaybeSync], which stays
  /// synchronous unless [paramsCapabilities] contains an import whose own
  /// ID isn't yet known synchronously — even then this is still strictly
  /// better than the fully generic path, since [importId] itself never
  /// needs awaiting either way.
  (int, Future<DispatchResult>) _startResolvedImportCall(
    int importId,
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) buildParams,
    List<Capability> paramsCapabilities,
  ) {
    if (_closedError != null) {
      throw RpcException('connection is closed', kind: ErrorKind.disconnected);
    }
    _importTable.throwIfBroken(importId);

    final question = _questionTable.allocate();
    final qid = question.id;
    final completer = question.returnCompleter!;
    final sentCompleter = question.sentCompleter!;
    sentCompleter.future.ignore();

    void onSent() {
      _questionTable.markSent(qid);
    }

    void onError(Object e, StackTrace st) {
      // Same invariant as _startCall's catchError: every path below that
      // reaches onError does so before _sendRaw ever runs (both the sync
      // branch and the async IIFE only call onSent(), never onError(), once
      // _sendRaw succeeds) — see _rollbackQuestionParamExports's doc comment.
      final ids = _questionTable.failBeforeSend(question, e, st);
      if (ids != null) _applyReleaseParamCaps(ids);
    }

    try {
      final builtOrFuture = buildCallMessageBuildingMaybeSync(
        questionId: qid,
        targetImportId: importId,
        interfaceId: interfaceId,
        methodId: methodId,
        buildParams: buildParams,
        resolveDescriptors:
            () => _resolveCapTableMaybeSync(paramsCapabilities, qid: qid),
      );
      if (builtOrFuture is Future<Uint8List>) {
        () async {
          try {
            final bytes = await builtOrFuture;
            _sendRaw(bytes);
            onSent();
          } catch (e, st) {
            onError(e, st);
          }
        }();
      } else {
        _sendRaw(builtOrFuture);
        onSent();
      }
    } catch (e, st) {
      onError(e, st);
    }

    return (qid, _awaitReturn(qid, completer));
  }

  /// Canonical async capTable resolution shared by [_buildAndSendCall],
  /// [_buildAndSendCallBuilding], and (via [_resolveCapTableMaybeSync])
  /// [_startResolvedImportCall]. When [qid] is given, records every
  /// senderHosted/senderPromise export ID produced (this call's own params
  /// capabilities) against it — see [_recordParamExportIds].
  Future<List<RpcCapDescriptor>> _resolveCapTable(
    List<Capability> paramsCapabilities, {
    int? qid,
  }) async {
    final capEntries = <RpcCapDescriptor>[];
    // try/finally, not a plain trailing call: a broken import or a rejected
    // _importIdFuture partway through this loop (_importTable.throwIfBroken/
    // await above) must still record whatever senderHosted/senderPromise exports
    // _getOrCreateExportId already created for entries processed *before*
    // that point — otherwise their refcount bump would never be visible to
    // _rollbackQuestionParamExports and would leak. See that method's doc
    // comment for the failure this guards against.
    try {
      for (final rawCap in paramsCapabilities) {
        // Generated client stubs commonly hand out a fresh
        // vendCapabilityHandle wrapper every time their underlying
        // capability is accessed (e.g. a `.capability` getter), so an `is
        // _ImportedCapability`/`is _WirePipelinedCapability` check against
        // the wrapper itself never matches even when it's genuinely an
        // import/pipeline from this same connection — unwrap first. See
        // unwrapVendedCapability's doc comment for the concrete failure
        // this avoids (a receiverHosted hand-back gets mis-encoded as a
        // brand-new senderHosted export instead).
        final cap = unwrapVendedCapability(rawCap);
        if (cap is _ImportedCapability && cap._conn == this) {
          final id = await cap._importIdFuture;
          _importTable.throwIfBroken(id);
          capEntries.add(RpcCapDescriptor.receiverHosted(id));
        } else if (cap is _WirePipelinedCapability &&
            cap._conn == this &&
            !cap._hasResolved) {
          // The parent Call (cap._parentQid) must reach the wire before this
          // receiverAnswer descriptor referencing it does — otherwise the
          // peer sees a question id it hasn't been told about yet and
          // rejects it (e.g. capnp-rust's "invalid 'receiver answer'").
          // Mirrors the promisedAnswer-*target* guard in
          // _buildAndSendCall/_buildAndSendCallBuilding, but for a param
          // capability referencing another question instead of this call's
          // own target.
          final parentSent = _questionTable.sentCompleterFor(cap._parentQid);
          if (parentSent != null) await parentSent.future;
          capEntries.add(
            RpcCapDescriptor.receiverAnswer(cap._parentQid, cap._transformPath),
          );
        } else {
          capEntries.add(
            RpcCapDescriptor.senderHosted(_exportTable.getOrCreate(cap)),
          );
        }
      }
    } finally {
      if (qid != null) _recordParamExportIds(qid, capEntries);
    }
    return capEntries;
  }

  /// Records the senderHosted/senderPromise export IDs among [capEntries]
  /// (an outgoing Call's own capTable — this vat's params capabilities)
  /// against [qid], so [_awaitReturn] can apply `Return.releaseParamCaps`
  /// locally once the matching Return arrives. A call with no such entries
  /// (no capability params, or every one an import/promisedAnswer pass-
  /// through) records nothing — nothing to release either way.
  void _recordParamExportIds(int qid, List<RpcCapDescriptor> capEntries) {
    final ids = <int>[
      for (final d in capEntries)
        if (d.disc == 1 || d.disc == 2) d.id,
    ];
    _questionTable.recordParamExportIds(qid, ids);
  }

  /// Synchronous variant of [_resolveCapTable] for [_startResolvedImportCall]:
  /// resolves synchronously when every capability is already locally
  /// resolvable (true for everything except an [_ImportedCapability] whose
  /// own import ID isn't cached yet), falling back to [_resolveCapTable]
  /// as a whole otherwise. Checking "is everything resolvable" up front,
  /// before touching anything with a side effect (like
  /// [_getOrCreateExportId], which isn't idempotent — it bumps a refcount
  /// on every call), avoids resolving some entries synchronously and then
  /// re-resolving the whole list again through [_resolveCapTable].
  FutureOr<List<RpcCapDescriptor>> _resolveCapTableMaybeSync(
    List<Capability> paramsCapabilities, {
    int? qid,
  }) {
    if (paramsCapabilities.isEmpty) return const [];
    final needsAsync = paramsCapabilities.any((rawCap) {
      final cap = unwrapVendedCapability(rawCap);
      return (cap is _ImportedCapability &&
              cap._conn == this &&
              cap._cachedState == null) ||
          // A not-yet-sent parent Call means the receiverAnswer branch below
          // would need to await it (see _resolveCapTable's matching
          // comment) — fall through to the async path instead of racing it.
          (cap is _WirePipelinedCapability &&
              cap._conn == this &&
              !cap._hasResolved &&
              _questionTable.sentCompleterFor(cap._parentQid) != null);
    });
    if (needsAsync) return _resolveCapTable(paramsCapabilities, qid: qid);

    final capEntries = <RpcCapDescriptor>[];
    // See _resolveCapTable's matching comment: try/finally so a broken
    // import discovered partway through still records whatever exports
    // earlier entries in this loop already created.
    try {
      for (final rawCap in paramsCapabilities) {
        // See _resolveCapTable's matching comment on why this unwraps
        // vendCapabilityHandle wrappers before checking the concrete type.
        final cap = unwrapVendedCapability(rawCap);
        if (cap is _ImportedCapability && cap._conn == this) {
          final id = cap._cachedState!.importId;
          _importTable.throwIfBroken(id);
          capEntries.add(RpcCapDescriptor.receiverHosted(id));
        } else if (cap is _WirePipelinedCapability &&
            cap._conn == this &&
            !cap._hasResolved) {
          // Safe to encode without waiting here: needsAsync above already
          // routed any case where the parent Call hasn't been sent yet
          // through _resolveCapTable's async (awaiting) version instead.
          capEntries.add(
            RpcCapDescriptor.receiverAnswer(cap._parentQid, cap._transformPath),
          );
        } else {
          capEntries.add(
            RpcCapDescriptor.senderHosted(_exportTable.getOrCreate(cap)),
          );
        }
      }
    } finally {
      if (qid != null) _recordParamExportIds(qid, capEntries);
    }
    return capEntries;
  }

  Future<void> _buildAndSendCall({
    required int qid,
    required Completer<void> sentCompleter,
    required Future<int>? importIdFuture,
    required int? targetPromisedAnswerQid,
    required List<int> targetTransformPath,
    required int interfaceId,
    required int methodId,
    required Uint8List paramsBytes,
    required List<Capability> paramsCapabilities,
    bool sendResultsToYourself = false,
  }) async {
    // For promisedAnswer targets, wait until the parent Call is on the wire so
    // the server always receives the parent before the pipelined call.
    if (targetPromisedAnswerQid != null) {
      final parentSent = _questionTable.sentCompleterFor(
        targetPromisedAnswerQid,
      );
      if (parentSent != null) await parentSent.future;
    }

    // Categorize each capability param:
    //   - Imported cap from this same peer → receiverHosted
    //   - Everything else → senderHosted export
    final capEntries = await _resolveCapTable(paramsCapabilities, qid: qid);

    if (targetPromisedAnswerQid != null) {
      _sendRaw(
        buildCallMessage(
          questionId: qid,
          targetPromisedAnswerQid: targetPromisedAnswerQid,
          targetTransformPath: targetTransformPath,
          interfaceId: interfaceId,
          methodId: methodId,
          paramsBytes: paramsBytes,
          capTableDescriptors: capEntries,
          sendResultsToYourself: sendResultsToYourself,
        ),
      );
    } else {
      final importId = await importIdFuture!;
      _importTable.throwIfBroken(importId);
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
    _questionTable.markSent(qid);
  }

  /// Zero-copy counterpart of [_startCall]: [buildParams] writes params
  /// directly into the outgoing Call's `Payload.content`, instead of the
  /// caller pre-building a standalone message. See [Capability.
  /// dispatchBuilding].
  ///
  /// [paramsCapabilities] may still be being appended to when this is
  /// called (see [Capability.dispatchBuilding]'s contract) — capTable
  /// resolution only reads it from inside [buildCallMessageBuilding]'s
  /// `resolveCapTable` callback, which [buildCallMessageBuilding] itself
  /// only invokes after [buildParams] has returned.
  (int, Future<DispatchResult>) _startCallBuilding(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) buildParams, {
    List<Capability> paramsCapabilities = const [],
    int? targetPromisedAnswerQid,
    List<int> targetTransformPath = const [],
  }) {
    if (_closedError != null) {
      throw RpcException('connection is closed', kind: ErrorKind.disconnected);
    }

    final question = _questionTable.allocate();
    final qid = question.id;
    final completer = question.returnCompleter!;
    final sentCompleter = question.sentCompleter!;
    sentCompleter.future.ignore();

    _buildAndSendCallBuilding(
      qid: qid,
      sentCompleter: sentCompleter,
      importIdFuture: importIdFuture,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetTransformPath: targetTransformPath,
      interfaceId: interfaceId,
      methodId: methodId,
      buildParams: buildParams,
      paramsCapabilities: paramsCapabilities,
    ).catchError((Object e, StackTrace st) {
      // Same invariant as _startCall's catchError, for
      // _buildAndSendCallBuilding instead — see _rollbackQuestionParamExports.
      final ids = _questionTable.failBeforeSend(question, e, st);
      if (ids != null) _applyReleaseParamCaps(ids);
    });

    final resultFuture = _awaitReturn(qid, completer);
    return (qid, resultFuture);
  }

  Future<void> _buildAndSendCallBuilding({
    required int qid,
    required Completer<void> sentCompleter,
    required Future<int>? importIdFuture,
    required int? targetPromisedAnswerQid,
    required List<int> targetTransformPath,
    required int interfaceId,
    required int methodId,
    required void Function(AnyPointerBuilder) buildParams,
    required List<Capability> paramsCapabilities,
    bool sendResultsToYourself = false,
  }) async {
    // For promisedAnswer targets, wait until the parent Call is on the wire so
    // the server always receives the parent before the pipelined call.
    if (targetPromisedAnswerQid != null) {
      final parentSent = _questionTable.sentCompleterFor(
        targetPromisedAnswerQid,
      );
      if (parentSent != null) await parentSent.future;
    }

    // Same categorization as _buildAndSendCall, just deferred until after
    // buildParams has run (see this method's doc comment) by living inside
    // resolveCapTable instead of running up front.
    Future<List<RpcCapDescriptor>> resolveCapTable() =>
        _resolveCapTable(paramsCapabilities, qid: qid);

    if (targetPromisedAnswerQid != null) {
      _sendRaw(
        await buildCallMessageBuilding(
          questionId: qid,
          targetPromisedAnswerQid: targetPromisedAnswerQid,
          targetTransformPath: targetTransformPath,
          interfaceId: interfaceId,
          methodId: methodId,
          buildParams: buildParams,
          resolveCapTable: resolveCapTable,
          sendResultsToYourself: sendResultsToYourself,
        ),
      );
    } else {
      final importId = await importIdFuture!;
      _importTable.throwIfBroken(importId);
      _sendRaw(
        await buildCallMessageBuilding(
          questionId: qid,
          targetImportId: importId,
          interfaceId: interfaceId,
          methodId: methodId,
          buildParams: buildParams,
          resolveCapTable: resolveCapTable,
          sendResultsToYourself: sendResultsToYourself,
        ),
      );
    }

    // Signal to any pipelined calls waiting on this question.
    _questionTable.markSent(qid);
  }

  Future<DispatchResult> _awaitReturn(
    int qid,
    Completer<RpcMessage> completer,
  ) async {
    final RpcMessage ret;
    final List<int>? paramExportIds;
    try {
      ret = await completer.future;
    } finally {
      // Whether or not a params-caps entry was ever recorded for this qid
      // (see _recordParamExportIds), drop it now — nothing past this point
      // reads _questionParamExportIds[qid] again, on any path (success,
      // exception, or completer failing before a Return ever arrived).
      // Captured into a local first so the success path below still has it
      // even though `finally` runs before that code does.
      paramExportIds = _questionTable.takeParamExportIds(qid);
    }

    // Only Return-results/Return-exception ever legitimately carry these —
    // see RpcMessage.returnReleaseParamCaps/returnNoFinishNeeded's doc
    // comment. releaseParamCaps applying to an exception Return, not just
    // results, mirrors buildReturnExceptionMessage's own support for it.
    final answersCall = ret.isReturnResults || ret.isReturnException;
    if (answersCall && ret.returnReleaseParamCaps && paramExportIds != null) {
      _applyReleaseParamCaps(paramExportIds);
    }
    if (!(answersCall && ret.returnNoFinishNeeded)) {
      _sendRaw(buildFinishMessage(qid, releaseResultCaps: false));
    }

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
      return DispatchResult(
        payload: RpcPayload.fromBytes(resolved.resultBytes),
        caps: resolved.caps,
      );
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

    final resultsContent = ret.resultsContent;
    return DispatchResult(
      payload:
          resultsContent != null
              ? RpcPayload.fromEnvelope(resultsContent)
              : RpcPayload.fromBytes(_emptyResultBytes),
      caps: caps,
    );
  }

  /// Resolves [qid] against this vat's own incoming-answer bookkeeping, for
  /// correlating a `Return.takeFromOtherQuestion` from the peer.
  ///
  /// Mirrors the resolved-then-pending lookup order [_handlePipelinedCall]
  /// already uses (see [AnswerTable.resolvedFor]/[AnswerTable.pendingFor]),
  /// with one extra case: failed
  /// answers are retained until Finish so a `takeFromOtherQuestion` that
  /// races with the failure still observes the original server exception
  /// rather than a misleading "unknown question id".
  Future<ResolvedAnswer> _resolveLocalAnswer(int qid) {
    final resolved = _answerTable.resolvedFor(qid);
    if (resolved != null) return Future.value(resolved);
    final pending = _answerTable.pendingFor(qid);
    if (pending != null) return pending;
    final error = _answerTable.errorFor(qid);
    if (error != null) throw error;
    throw RpcException(
      'takeFromOtherQuestion referenced unknown question id $qid',
    );
  }

  // 24-byte message: struct with 0 data words, 1 pointer word = CapabilityPointer(0).
  // Used as the synthesised result for Bootstrap answers so that pipelined
  // calls targeting {receiverAnswer: {questionId: <boot>, transform: []}}
  // can resolve ptr[0] → the resolved answer's caps[0] (see
  // AnswerTable.resolvedFor).
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

  /// The returned Future always completes successfully (never with an
  /// error), and does so even if the underlying sink fails partway through
  /// the batched flush — see [_flushPendingReleases]'s doc comment for why.
  /// Callers (only [_ImportedCapability.dispose]) can therefore always
  /// `await` it without a `try`/`catch`.
  Future<void> _releaseImport(int importId) {
    if (!_importTable.releaseAndBatch(importId, _disposeIgnoringErrors)) {
      return Future.value();
    }
    return _releaseFlushFuture ??= Future.microtask(_flushPendingReleases);
  }

  /// Sends one batched Release per import ID accumulated since the last
  /// flush — see [_releaseImport]/[ImportTable.takeBatchedReleases].
  ///
  /// Never throws, and never leaves a Release permanently un-sent while the
  /// connection is still usable: [_sendRaw] catches any synchronous sink
  /// failure itself and tears the connection down (setting [_closedError])
  /// rather than propagating it here, so this loop can't partially fail in
  /// a way callers would need to react to. Once torn down, this loop stops
  /// calling [_sendRaw] for the remaining entries instead of trying (and
  /// silently no-op'ing on) each one — deliberately dropping them
  /// unsent, not retrying later: a torn-down connection means the peer
  /// discards every export it held for this vat anyway (matching this
  /// vat's own [_tearDown] clearing its side symmetrically), so there is no
  /// longer anything for a Release to reconcile.
  void _flushPendingReleases() {
    _releaseFlushFuture = null;
    final pending = _importTable.takeBatchedReleases();
    if (pending.isEmpty) return;
    for (final entry in pending.entries) {
      if (_closedError != null) return;
      _sendRaw(buildReleaseMessage(entry.key, entry.value));
    }
  }

  /// Ends [tracker]'s deferred-release window (a no-op, returning `true`,
  /// for a null/empty tracker — no capability params means nothing to
  /// release) and decides `Return.releaseParamCaps`: `true` when every
  /// params capability freshly imported for the call was disposed before it
  /// settled — their wire Release was already folded into the refcount
  /// decrement done by [_ImportedCapability]'s deferred sink and none needs
  /// sending — otherwise flushes an explicit Release for just the ones that
  /// were disposed and returns `false`. Either way, clears each wrapper's
  /// sink so a *later* dispose() of one that's still outstanding goes
  /// through the normal (non-deferred) [_releaseImport] path.
  bool _finalizeParamCapsTracker(_ParamCapsReleaseTracker? tracker) {
    if (tracker == null) return true;
    for (final wrapper in tracker.wrappers) {
      wrapper._deferredReleaseSink = null;
    }
    if (tracker.disposedImportIds.length == tracker.wrappers.length) {
      return true;
    }
    for (final id in tracker.disposedImportIds) {
      _sendRaw(buildReleaseMessage(id, 1));
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Internal: message loop
  // ---------------------------------------------------------------------------

  void _runMessageLoop(Stream<Uint8List> incoming) {
    final decoderInput = StreamController<Uint8List>(sync: true);
    _decoderInput = decoderInput;
    final sourceSubscription = incoming.listen(
      decoderInput.add,
      onError: decoderInput.addError,
      onDone: decoderInput.close,
    );
    _incomingSourceSubscription = sourceSubscription;
    if (_closedError != null) {
      _incomingSourceSubscription = null;
      sourceSubscription.cancel().ignore();
    }
    // Use raw-bytes stream so the Unimplemented handler can echo the
    // original. `_preFramed` transports (WebSocket) already deliver one
    // complete message per event, so they skip the generic byte-buffering
    // deframer entirely rather than feeding already-whole messages through
    // it.
    final rawMessages =
        _preFramed
            ? MessageStream.deserializeFramedStreamRaw(decoderInput.stream)
            : MessageStream.deserializeStreamRaw(decoderInput.stream);
    final subscription = rawMessages.listen(
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
            RpcException(
              'invalid incoming RPC message: $error',
              kind: error is CapnpException ? error.kind : ErrorKind.failed,
              cause: error,
            ),
            stackTrace: stackTrace,
          );
        }
      },
      onError:
          (Object error, StackTrace stackTrace) =>
              _tearDown(error, stackTrace: stackTrace),
      onDone: () => _tearDown(null),
    );
    _incomingSubscription = subscription;
    if (_closedError != null) {
      _incomingSubscription = null;
      subscription.cancel().ignore();
    }
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
    // exactly like ExportTable.getOrCreate does for capabilities returned
    // from ordinary calls — without this, a peer that bootstraps twice and
    // later disposes just one of the two resulting capabilities would drop
    // this side's refcount to 0 and dispose the capability out from under
    // the peer's other, still-live reference.
    // Register the bootstrap answer so pipelined calls targeting
    // {receiverAnswer: {questionId: msg.questionId, transform: []}} can
    // resolve ptr[0] → the bootstrap capability.
    final bootstrapCap = _exportTable.retainExisting(0);
    if (bootstrapCap != null) {
      _answerTable.setResolved(
        msg.questionId,
        ResolvedAnswer(_bootstrapResultBytes, [bootstrapCap]),
      );
    }
  }

  void _handleCall(RpcMessage msg) {
    if (msg.targetIsPromisedAnswer) {
      _handlePipelinedCall(msg);
      return;
    }

    final identity = _exportTable.identityFor(msg.targetImportId);
    if (identity == null) {
      _sendRaw(
        buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'unknown export id: ${msg.targetImportId}',
        ),
      );
      return;
    }
    _dispatchToCapability(msg, identity);
  }

  void _handlePipelinedCall(RpcMessage msg) {
    final parentQid = msg.targetPromisedAnswerQid;
    // An empty/noop-only transform is normalized to a single hop at pointer
    // slot 0. The only case where a peer legitimately sends one is a
    // promisedAnswer targeting a Bootstrap answer's capability directly —
    // Bootstrap's result has no wrapping wire struct (there's no field to
    // traverse), and this vat's own synthesized _bootstrapResultBytes
    // wrapper always places that capability at ptr slot 0 to match (see
    // _handleBootstrap). A real method's result is always a real struct, so
    // a well-behaved peer never sends an empty transform for anything else.
    final path =
        msg.targetTransformPath.isEmpty ? const [0] : msg.targetTransformPath;

    // Already resolved: dispatch immediately.
    final resolved = _answerTable.resolvedFor(parentQid);
    if (resolved != null) {
      final cap = _capFromPath(resolved, path);
      if (cap == null) {
        _sendRaw(
          buildReturnExceptionMessage(
            answerId: msg.questionId,
            reason: 'pointer path $path in result struct is not a capability',
          ),
        );
        return;
      }
      _dispatchToCapability(msg, cap);
      return;
    }

    // Still pending: queue behind the parent dispatch.
    final pending = _answerTable.pendingFor(parentQid);
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
          final cap = _capFromPath(resolved, path);
          if (cap == null) {
            _sendRaw(
              buildReturnExceptionMessage(
                answerId: msg.questionId,
                reason:
                    'pointer path $path in result struct is not a capability',
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

  Capability? _capFromPath(ResolvedAnswer resolved, List<int> path) =>
      capabilityFromResultPath(
        DispatchResult(
          payload: RpcPayload.fromBytes(resolved.resultBytes),
          caps: resolved.caps,
        ),
        path,
      );

  void _dispatchToCapability(RpcMessage msg, Capability cap) {
    final qid = msg.questionId;
    if (_rejectDuplicateQuestionId(qid)) return;
    final paramsContent = msg.paramsContent;
    final params =
        paramsContent != null
            ? RpcPayload.fromEnvelope(paramsContent)
            : RpcPayload.fromBytes(_emptyResultBytes);

    // Resolve capabilities from the incoming capTable.
    // Each entry in the list must correspond 1-to-1 with the capTable index,
    // because capability pointers in the params struct reference these indices.
    // `none` descriptors get a NullCapability placeholder so subsequent
    // indices remain correct. Unsupported descriptors are protocol errors:
    // silently treating them as null loses information and can change the
    // meaning of an otherwise valid call.
    final paramsCapabilities = <Capability>[];
    try {
      for (final descriptor in msg.capTableDescriptors) {
        paramsCapabilities.add(_capabilityFromDescriptor(descriptor));
      }
    } catch (error) {
      // Every entry decoded successfully before whatever failed is a real,
      // live reference (an import refcount bump, a vended receiverHosted
      // handle, ...) — dispose them *before* deciding what to do with the
      // error itself, including the unimplemented/rethrow path below,
      // which tears the whole connection down: _tearDown only ever
      // disposes each export's own single `ownedReference` (see that
      // field's doc comment) — it has no way to know about an *additional*
      // handle vended into a local variable like this one, so leaving one
      // undisposed here would leak a permanent share of that identity's
      // refcount, potentially high enough that its own real capability
      // never actually gets disposed even once every other reference to it
      // (including the export's own) is long gone. A malicious peer could
      // repeat this pattern — one valid entry, then an invalid one — every
      // connection to accumulate exactly such leaked references.
      for (final capability in paramsCapabilities) {
        _disposeIgnoringErrors(capability);
      }

      // A disc this vat doesn't implement at all (e.g. thirdPartyHosted) is
      // a bigger deal than a single bad call — see the `default` case in
      // _capabilityFromDescriptor and the "tears down the connection as
      // unimplemented" test for this exact behavior — so let that kind
      // keep propagating to this listener's own outer try/catch, which
      // tears the whole connection down. Same for anything that isn't even
      // an RpcException: _capabilityFromDescriptor itself never throws
      // anything else today, but this being a peer-triggered decode loop,
      // silently downgrading an unexpected failure type to an ordinary
      // per-call Return.exception would be the wrong default.
      if (error is! RpcException || error.kind == ErrorKind.unimplemented) {
        rethrow;
      }

      // Every other decode failure here (e.g. a receiverHosted descriptor
      // naming an export id we don't have) is just this one call's
      // problem: fail only it, with a normal Return.exception, and keep
      // serving the connection.
      //
      // Registers qid as answered — with no result-capability export ids
      // to release later, since this call never reached a real dispatch —
      // so _rejectDuplicateQuestionId can still catch a peer illegally
      // reusing this same qid before sending Finish for it, exactly like
      // every other Return sent without a real dispatch throughout this
      // file (see the sibling `_answerTable.recordAnswered(qid, const [])`
      // sites).
      _answerTable.recordAnswered(qid, const []);

      _sendRaw(
        buildReturnExceptionMessage(
          answerId: qid,
          reason: error.message,
          // The dispose() calls above already sent a real wire Release for
          // every import successfully resolved before the failing
          // descriptor (see _ImportedCapability.dispose()) — leaving this
          // at its default (true) would additionally tell the peer it
          // doesn't need to send its own Release for those same export
          // ids, so it would apply *both*: its own remoteRefCount would be
          // decremented twice for what was really only one release,
          // potentially tearing its own capability down while some other
          // legitimate reference to it is still outstanding.
          releaseParamCaps: false,
        ),
      );
      return;
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
        _answerTable.recordAnswered(qid, const []);
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
            // "unknown promisedAnswer questionId", since qid's resolved/
            // pending answer state is deliberately never populated here.
            _answerTable.recordAnswered(qid, const []);
          })
          .catchError((Object err) {
            if (_closedError != null) return;
            _answerTable.recordAnswered(qid, const []);
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
      tailCall.params,
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
    final question = _questionTable.allocate();
    final qid = question.id;
    final completer = question.returnCompleter;
    final sentCompleter = question.sentCompleter!;

    _buildAndSendCall(
      qid: qid,
      sentCompleter: sentCompleter,
      importIdFuture: target._importIdFuture,
      targetPromisedAnswerQid: null,
      targetTransformPath: const [],
      interfaceId: tailCall.interfaceId,
      methodId: tailCall.methodId,
      paramsBytes: tailCall.params.bytes,
      paramsCapabilities: tailCall.paramsCapabilities,
      sendResultsToYourself: true,
    ).catchError((Object e, StackTrace st) {
      // Same invariant as _startCall's catchError — see
      // _rollbackQuestionParamExports. Usually a no-op here: tailCall's
      // params are almost always _ImportedCapability from this same
      // connection, which _resolveCapTable categorizes as receiverHosted
      // (no export created) — but a receiverHosted-descriptor param on the
      // *original* incoming call resolves to this vat's own capability
      // object (see _capabilityFromDescriptor's disc-3 case), which *does*
      // get a fresh senderHosted export when forwarded here.
      final ids = _questionTable.failBeforeSend(question, e, st);
      if (ids != null) _applyReleaseParamCaps(ids);
    });

    completer!.future
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
    RpcPayload params,
    List<Capability> paramsCapabilities, {
    bool sendResultsToYourself = false,
  }) {
    final cancellation = DispatchCancellationController();
    _answerTable.trackCancellation(qid, cancellation);

    // Params capabilities freshly imported for this call (see
    // _dispatchToCapability/_capabilityFromDescriptor — every senderHosted/
    // senderPromise entry in the incoming Call's capTable creates a brand
    // new _ImportedCapability wrapper) get a deferred release sink for the
    // lifetime of this dispatch, so Return.releaseParamCaps can be set
    // without an extra wire Release when the callee turns out not to need
    // them past the call — see _finalizeParamCapsTracker.
    final paramImportWrappers = paramsCapabilities
        .whereType<_ImportedCapability>()
        .where((c) => c._conn == this)
        .toList(growable: false);
    final paramCapsTracker =
        paramImportWrappers.isEmpty
            ? null
            : _ParamCapsReleaseTracker(paramImportWrappers);
    if (paramCapsTracker != null) {
      for (final wrapper in paramImportWrappers) {
        wrapper._deferredReleaseSink = (id) {
          _importTable.decrementRefcount(id, _disposeIgnoringErrors);
          paramCapsTracker.disposedImportIds.add(id);
        };
      }
    }

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
      (r) => ResolvedAnswer(r.payload.bytes, r.caps),
    );
    resolvedFuture.ignore();
    _answerTable.trackPending(qid, resolvedFuture);

    dispatchFuture
        .then((result) {
          _answerTable.dispatchSettled(qid);
          // The connection was torn down while this dispatch was still
          // running. _tearDown() already cleared the answer tables; don't
          // resurrect an entry for a peer that's no longer there. _sendRaw()
          // below would silently no-op anyway, but skip the bookkeeping too
          // so nothing lingers for a caller to observe as a leak. The result
          // is never sent as a Return, so any capabilities it carries would
          // otherwise never be disposed — dispose them here instead.
          if (_closedError != null) {
            _disposeResultCapabilities(result);
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          if (_answerTable.consumeIfAlreadyFinished(qid)) {
            _disposeResultCapabilities(result);
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          _answerTable.setResolved(
            qid,
            ResolvedAnswer(result.payload.bytes, result.caps),
          );

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
            _answerTable.recordAnswered(qid, const []);
            // No Return field exists on this variant to carry
            // releaseParamCaps, so just flush any deferred params releases
            // as ordinary Release messages.
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }

          final resultDescriptors = <RpcCapDescriptor>[];
          for (final c in result.caps) {
            resultDescriptors.add(_returnCapDescriptor(c));
          }
          final releaseParamCaps = _finalizeParamCapsTracker(paramCapsTracker);
          // No capabilities anywhere in the results means no wire-level
          // pipelined call against this answer could ever resolve to
          // anything but "not a capability" — so it's safe to tell the peer
          // no Finish is needed and immediately drop the answer's
          // pipelining bookkeeping ourselves, instead of waiting for it.
          final noFinishNeeded = resultDescriptors.isEmpty;
          // getRootRaw() resolves in place for an envelope- or
          // builder-backed payload (no serialize-then-reparse round trip;
          // see RpcPayload/buildReturnResultsMessageFromReader) and only
          // falls back to parsing bytes for a genuinely bytes-backed one.
          _sendRaw(
            buildReturnResultsMessageFromReader(
              answerId: qid,
              resultsRoot: result.payload.getRootRaw(),
              descriptors: resultDescriptors,
              releaseParamCaps: releaseParamCaps,
              noFinishNeeded: noFinishNeeded,
            ),
          );
          if (noFinishNeeded) {
            _answerTable.dropResolved(qid);
          } else {
            _answerTable.recordAnswered(qid, [
              for (final d in resultDescriptors)
                if (d.disc == 1 || d.disc == 2) d.id,
            ]);
          }
        })
        .catchError((Object err) {
          _answerTable.dispatchSettled(qid);
          _answerTable.dropResolved(qid);
          // See the matching comment in the success branch above.
          if (_closedError != null) {
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          if (_answerTable.consumeIfAlreadyFinished(qid)) {
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          final rpcError =
              err is CapnpException
                  ? err
                  : RpcException(err.toString(), kind: ErrorKind.failed);
          if (sendResultsToYourself) {
            _answerTable.recordError(qid, rpcError);
            _answerTable.recordAnswered(qid, const []);
            _sendRaw(buildReturnResultsSentElsewhereMessage(answerId: qid));
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          final releaseParamCaps = _finalizeParamCapsTracker(paramCapsTracker);
          // An exception Return never carries a results payload/capTable,
          // so — same reasoning as the noFinishNeeded branch above — no
          // Finish is ever needed for it, and no answer-lifecycle state
          // needs to be recorded for this qid at all.
          _sendRaw(
            buildReturnExceptionMessage(
              answerId: qid,
              reason: rpcError.message,
              kind: rpcError.kind,
              releaseParamCaps: releaseParamCaps,
              noFinishNeeded: true,
            ),
          );
        });
  }

  void _handleFinish(RpcMessage msg) {
    final resultExportIds = _answerTable.finish(msg.questionId);
    if (resultExportIds == null || !msg.releaseResultCaps) return;
    for (final eid in resultExportIds) {
      _exportTable.release(eid, _disposeIgnoringErrors);
    }
  }

  void _handleReturn(RpcMessage msg) {
    final completer = _questionTable.takeReturn(msg.answerId);
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
    final remoteRefCount = _exportTable.remoteRefCountFor(msg.releaseId);
    if (remoteRefCount == null) return;
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
    if (msg.referenceCount > remoteRefCount) {
      _tearDown(
        RpcException(
          'protocol violation: Release(id=${msg.releaseId}) referenceCount '
          '${msg.referenceCount} exceeds outstanding remote reference count '
          '$remoteRefCount',
        ),
      );
      return;
    }
    _exportTable.releaseRef(
      msg.releaseId,
      msg.referenceCount,
      _disposeIgnoringErrors,
    );
  }

  /// Applies `Return.releaseParamCaps` locally: for each export ID this vat
  /// put in the answered Call's own capTable (its params capabilities, from
  /// [_recordParamExportIds]), releases exactly one reference — the same
  /// effect an explicit `Release(id, 1)` from the peer would have had, without
  /// the peer needing to actually send one.
  void _applyReleaseParamCaps(List<int> exportIds) {
    for (final id in exportIds) {
      _exportTable.releaseRef(id, 1, _disposeIgnoringErrors);
    }
  }

  /// Undoes [_recordParamExportIds]/`ExportTable.getOrCreate`'s refcount bump
  /// for [qid]'s params capabilities when the Call itself never reached
  /// [_sendRaw] — e.g. `importIdFuture` rejects, or a broken-import check
  /// throws, after cap table resolution already ran. The peer never
  /// received anything in that case, so there is no reference for it to
  /// `Release`; a real one from `Return.releaseParamCaps` would go through
  /// [_applyReleaseParamCaps] instead, once a Return can even exist. Callers
  /// (the `catchError`/`onError` handlers alongside every `_buildAndSendCall`
  /// / `_buildAndSendCallBuilding` / `_startResolvedImportCall` attempt) only
  /// ever run for a build/send that failed before committing anything to the
  /// wire — see each call site's own doc comment for why that invariant
  /// holds — so this is safe to call unconditionally there, with no separate
  /// "was it actually sent" flag to track.

  void _handleResolve(RpcMessage msg) {
    if (msg.isResolveException) {
      // Mirror the success branch below: if we've already fully released
      // this import, a Resolve that arrives late must not resurrect
      // tracking state for it — ImportTable.stateFor would otherwise create
      // a brand new ImportState/broken-import entry that nothing will ever
      // clean up.
      if (!_importTable.isTracked(msg.promiseId)) return;
      final state = _importTable.stateFor(msg.promiseId);
      final error = RpcException(
        msg.exceptionReason ?? 'promise resolved to exception',
        kind: msg.exceptionKind,
      );
      _importTable.markBroken(msg.promiseId, error);
      state.resolveError(error);
      return;
    }

    final descriptor = msg.resolveCapDescriptor;
    if (descriptor == null) return;
    if (!_importTable.isTracked(msg.promiseId)) {
      if (descriptor.disc == 1 || descriptor.disc == 2) {
        _sendRaw(buildReleaseMessage(descriptor.id, 1));
      }
      return;
    }

    final state = _importTable.stateFor(msg.promiseId);
    final replacement = _capabilityFromDescriptor(descriptor);
    if (state.receivedCall && _isLocalCapability(replacement)) {
      final completer = Completer<void>();
      final embargoId = _embargoTable.register(
        completer,
        timeout: _disembargoTimeout,
      );
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
      _embargoTable.resolve(msg.disembargoContextId);
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
        targetTransformPath: msg.disembargoTargetTransformPath,
        contextDisc: 1,
        contextId: msg.disembargoContextId,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// If [qid] already has tracked answer-lifecycle state (from Bootstrap or
  /// an in-flight/finished Call — see [AnswerTable.isTracked]), tears the
  /// connection down as a protocol violation and returns true. A
  /// well-behaved peer never reuses a question ID before it has fully
  /// settled (Finish sent and Return received) — if it does anyway,
  /// registering the new dispatch would silently clobber the cancellation
  /// and pending/resolved-answer state for the still-live one, corrupting
  /// cancellation and Return/Finish bookkeeping for both.
  bool _rejectDuplicateQuestionId(int qid) {
    if (!_answerTable.isTracked(qid)) return false;
    _tearDown(
      RpcException('protocol violation: duplicate incoming question ID $qid'),
    );
    return true;
  }

  /// [cap] may be a [vendCapabilityHandle] handle — e.g. an application's
  /// dispatch handler read a capability out of another call's result via
  /// [requireCapabilityFromResult] and is now returning that same handle as
  /// part of its own result (or relaying it into a call on a different
  /// connection's — see [ExportTable]'s `_ExportEntry.ownedReference`) —
  /// so it's unwrapped to its real identity before being used as
  /// [ExportTable.getOrCreate]'s dedup key.
  ///
  /// `DispatchResult.caps` transfers ownership of [cap] to this connection
  /// — [ExportTable.getOrCreate] establishes (or reuses) this connection's
  /// own owning reference to [identity], so if [cap] was itself a distinct
  /// vended handle, it's now redundant with that owning reference and is
  /// disposed here: otherwise its share of [identity]'s refcount (see
  /// [vendCapabilityHandle]) would never be released, leaking the
  /// underlying capability even after every other reference to it —
  /// including this connection's own owning one — is properly disposed.
  RpcCapDescriptor _returnCapDescriptor(Capability cap) {
    final identity = unwrapVendedCapability(cap);
    final RpcCapDescriptor descriptor;
    if (identity is DeferredCapability) {
      final promiseId = _exportTable.getOrCreate(identity);
      _scheduleSenderPromiseResolve(promiseId, identity);
      descriptor = RpcCapDescriptor.senderPromise(promiseId);
    } else {
      descriptor = RpcCapDescriptor.senderHosted(
        _exportTable.getOrCreate(identity),
      );
    }
    if (!identical(cap, identity)) {
      _disposeIgnoringErrors(cap);
    }
    return descriptor;
  }

  void _scheduleSenderPromiseResolve(
    int promiseId,
    DeferredCapability promise,
  ) {
    if (!_exportTable.markScheduled(promiseId)) return;

    promise.resolution
        .then(
          (resolved) async {
            _exportTable.clearScheduled(promiseId);
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
                _exportTable.release(descriptor.id, _disposeIgnoringErrors);
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
            _exportTable.clearScheduled(promiseId);
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

  bool _isStillExportedPromise(int promiseId, DeferredCapability promise) =>
      _exportTable.isCurrentIdentity(promiseId, promise);

  /// See [_returnCapDescriptor]'s doc comment — [cap] is unwrapped to its
  /// real identity first, and a redundant vended [cap] is disposed at the
  /// end, for the same ownership-transfer reason (this resolves a promise
  /// a [DeferredCapability] returned from `DispatchResult.caps` settled
  /// to, which transfers ownership exactly like an already-settled result
  /// capability does). The `receiverHosted` branch establishes no owning
  /// reference of its own locally (it's just handing the peer back its own
  /// capability) — [cap] disposal is what releases its share of
  /// [identity]'s refcount there, since nothing else will.
  Future<RpcCapDescriptor> _resolveDescriptorForCapability(
    Capability cap,
  ) async {
    final identity = unwrapVendedCapability(cap);
    final RpcCapDescriptor descriptor;
    if (identity is _ImportedCapability && identity._conn == this) {
      final id = await identity._importIdFuture;
      _importTable.throwIfBroken(id);
      descriptor = RpcCapDescriptor.receiverHosted(id);
    } else if (identity is DeferredCapability) {
      final nestedPromiseId = _exportTable.getOrCreate(identity);
      _scheduleSenderPromiseResolve(nestedPromiseId, identity);
      descriptor = RpcCapDescriptor.senderPromise(nestedPromiseId);
    } else {
      descriptor = RpcCapDescriptor.senderHosted(
        _exportTable.getOrCreate(identity),
      );
    }
    if (!identical(cap, identity)) {
      _disposeIgnoringErrors(cap);
    }
    return descriptor;
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
      case 0: // none
        return NullCapability();
      case 1: // senderHosted
        final state = _importTable.retain(descriptor.id);
        return _ImportedCapability.fromState(this, state);
      case 2: // senderPromise
        final state = _importTable.retain(descriptor.id, isPromise: true);
        return _ImportedCapability.fromState(this, state);
      case 3: // receiverHosted: we (the receiver) export this cap
        // A fresh vendCapabilityHandle, not the export's own identity/
        // ownedReference directly: this capability is handed to
        // application code (a call's paramsCapabilities, a Return's result
        // caps, or a resolved promise replacement), which routinely
        // disposes params/result capabilities it's done with — that must
        // decrement the shared refcount (see vendCapabilityHandle) rather
        // than tearing down the export's identity directly, which would
        // invalidate the export's own still-live ownedReference (and any
        // other outstanding reference to the same identity) out from under
        // it. Code that needs to recognize the concrete capability this
        // wraps (e.g. an `is`/identity check against a locally-known
        // object) must unwrap it first — see unwrapVendedCapability's doc
        // comment; this is the same discipline every other decode path
        // (requireCapabilityFromResult et al.) already requires.
        final identity = _exportTable.identityFor(descriptor.id);
        if (identity == null) {
          // A well-behaved peer, honoring the protocol's causal ordering
          // guarantees, never references an export id we haven't actually
          // exported to it — this is a genuine protocol violation (a buggy
          // or malicious peer), not a legitimate race. Silently mapping it
          // to NullCapability would conflate it with a schema-level `none`
          // descriptor (disc 0), losing that distinction and, per
          // _dispatchToCapability's own doc comment on this same class of
          // decision, changing the meaning of an otherwise valid call.
          throw RpcException(
            'unknown receiverHosted export id: ${descriptor.id}',
          );
        }
        return vendCapabilityHandle(identity);
      case 4: // receiverAnswer: capability in one of our outstanding answers
        return _ReceiverAnswerCapability(
          this,
          descriptor.questionId,
          // See _handlePipelinedCall's matching comment: an empty/noop-only
          // transform is normalized to a single hop at pointer slot 0
          // (legitimate only for a Bootstrap answer's capability, which has
          // no wrapping struct to traverse).
          descriptor.path.isEmpty ? const [0] : descriptor.path,
        );
      default:
        throw RpcException(
          'unsupported capability descriptor (disc=${descriptor.disc})',
          kind: ErrorKind.unimplemented,
        );
    }
  }

  int? _importIdFromDescriptor(RpcCapDescriptor descriptor) {
    if (descriptor.disc != 1 && descriptor.disc != 2) return null;
    _importTable.retain(descriptor.id, isPromise: descriptor.disc == 2);
    return descriptor.id;
  }

  bool _isLocalCapability(Capability cap) {
    if (cap is _ImportedCapability && cap._conn == this) return false;
    if (cap is _WirePipelinedCapability && cap._conn == this) return false;
    return true;
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

    final incomingSourceSubscription = _incomingSourceSubscription;
    _incomingSourceSubscription = null;
    if (incomingSourceSubscription != null) {
      try {
        incomingSourceSubscription.cancel().ignore();
      } catch (_) {}
    }
    final decoderInput = _decoderInput;
    _decoderInput = null;
    if (decoderInput != null) {
      try {
        decoderInput.close().ignore();
      } catch (_) {}
    }
    final incomingSubscription = _incomingSubscription;
    _incomingSubscription = null;
    if (incomingSubscription != null) {
      try {
        incomingSubscription.cancel().ignore();
      } catch (_) {}
    }

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
    _questionTable.tearDown(err);

    if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
      _bootstrapCompleter!.future.ignore();
      _bootstrapCompleter!.completeError(err);
    }

    _answerTable.tearDown();

    // Dispose all exported capabilities (each export's own owned
    // reference — see ExportTable's own doc comment).
    _exportTable.tearDown(_disposeIgnoringErrors);
    _importTable.tearDown();
    _embargoTable.tearDown(err);

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

  int get debugPendingQuestionCount => _questionTable.pendingCount;
  int get debugPendingQuestionSentCount => _questionTable.pendingSentCount;

  /// Number of capabilities currently exported to the peer (i.e. still
  /// holding at least one outstanding remote reference).
  int get debugExportCount => _exportTable.count;

  /// Number of remote capabilities currently imported from the peer (i.e.
  /// still holding at least one outstanding local reference).
  int get debugImportCount => _importTable.count;

  /// Number of imports recorded as broken (their promise resolved to an
  /// exception). Tracked separately from [debugImportCount] because a
  /// broken import can still be observed after the import itself is
  /// released — this should settle back to zero once every import that
  /// ever broke has also been fully released.
  int get debugBrokenImportCount => _importTable.brokenCount;

  /// Number of import IDs with a Release batched but not yet flushed to the
  /// wire (see [_releaseImport]/[_flushPendingReleases]). Always zero
  /// between microtasks — it's only ever non-zero for the duration of a
  /// single, already-scheduled flush, and [_flushPendingReleases] clears it
  /// up front before that flush sends anything (so a mid-flush sink failure
  /// never leaves it non-empty either).
  int get debugPendingReleaseCount => _importTable.pendingReleaseCount;

  /// Number of incoming calls with some tracked answer-lifecycle state:
  /// dispatch in flight, a resolved-but-not-yet-finished answer, or a
  /// Finish that arrived before dispatch completed. Zero means every
  /// incoming call this connection has seen has fully settled.
  int get debugAnswerCount => _answerTable.count;

  /// Number of incoming dispatches with a live [DispatchCancellationController]
  /// (i.e. dispatch is still running and could still observe cancellation).
  int get debugCancellationCount => _answerTable.cancellationCount;

  /// Number of Disembargo round-trips currently awaiting the peer's
  /// receiverLoopback response.
  int get debugEmbargoCount => _embargoTable.count;
}
