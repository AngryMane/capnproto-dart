import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:meta/meta.dart';

import '../capability/capability.dart'
    show Capability, DispatchCancellationController, unwrapCapabilityLease;
import '../capability/capability_factory.dart';
import 'calls/answer_table.dart';
import 'calls/incoming_call_coordinator.dart';
import 'calls/outgoing_call.dart';
import 'calls/outgoing_call_coordinator.dart';
import 'calls/question_table.dart';
import 'capabilities/capability_protocol.dart';
import 'capabilities/embargo_table.dart';
import 'capabilities/export_table.dart';
import 'capabilities/import_table.dart';
import 'capabilities/rpc_capability.dart';
import 'capabilities/rpc_capability_delegate.dart';
import 'flow_controller.dart';
import 'rpc_connection.dart';
import 'rpc_exception.dart';
import 'rpc_message_codec.dart';

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

  // Answers: incoming calls this vat is currently (or has recently)
  // answered — see AnswerTable's own doc comment.
  final AnswerTable _answerTable = AnswerTable();
  final EmbargoTable _embargoTable = EmbargoTable();

  // Set to a non-null error once the connection is closed.
  Object? _closedError;
  final Completer<void> _closedCompleter = Completer<void>();

  // The bootstrap capability reference on this connection (client side).
  // Resolved after the Bootstrap exchange completes. Plain [Capability] —
  // nothing here ever uses an _ImportedCapability-specific member on it,
  // only `factory.fromCapability(_bootstrapCap!)` and the `!= null` cache
  // check — so there's no need to name the concrete RPC capability proxy
  // type.
  Capability? _bootstrapCap;
  // Completer for the bootstrap handshake.
  Completer<int>? _bootstrapCompleter;
  // Question ID used for the Bootstrap message (so _handleBootstrapReturn
  // can distinguish the bootstrap return from regular call returns).
  int? _bootstrapQuestionId;

  // Every RPC capability proxy this connection leases
  // (`_ImportedCapability`/`_PipelinedCapability`/`_ReceiverAnswerCapability`
  // in `rpc_capability.dart`) is bound to this [RpcCapabilityDelegate]. One
  // instance lives for the whole connection lifetime, so
  // identical(cap._delegate, _rpcCapabilityDelegate) reliably means "this
  // capability belongs to this connection", the same way `cap._delegate ==
  // this` did back when those classes held a TwoPartyRpcConnection directly.
  // `late` lets the initializer reference `this`.
  late final RpcCapabilityDelegate _rpcCapabilityDelegate =
      _TwoPartyRpcCapabilityDelegate(this);

  // Stable callback shared by every incoming Call's params-cap release
  // window, so opening a window does not allocate another escaping closure.
  // ignore: prefer_function_declarations_over_variables, stable identity is intentional
  late final void Function(int) _decrementImportReference = (importId) {
    _importTable.decrementRefcount(importId, _disposeIgnoringErrors);
  };

  // Capability wire protocol: descriptor encode/decode, import/export
  // bookkeeping glue, senderPromise resolution, Release, Resolve, and
  // Disembargo handling — see CapabilityProtocol's own doc comment for why
  // it's a standalone, constructor-injected class rather than another
  // private extension. `late` for the same reason as [_rpcCapabilityDelegate]: the
  // bound method tear-offs below capture `this`.
  late final CapabilityProtocol _capabilityProtocol = CapabilityProtocol(
    exportTable: _exportTable,
    importTable: _importTable,
    embargoTable: _embargoTable,
    questions: _questionTable,
    disembargoTimeout: _disembargoTimeout,
    sendBytes: _sendRaw,
    disposeIgnoringErrors: _disposeIgnoringErrors,
    isClosed: () => _closedError != null,
    tearDownConnection: (error) => _tearDown(error),
    tryExtractCapabilityReference:
        (cap) => tryExtractRpcCapabilityReference(_rpcCapabilityDelegate, cap),
    isSameConnectionPeerCapability:
        (cap) => isSameConnectionPeerCapability(_rpcCapabilityDelegate, cap),
    importedCapabilityFromState:
        (state) =>
            createImportedCapabilityFromState(_rpcCapabilityDelegate, state),
    receiverAnswerCapability:
        (questionId, path) => createReceiverAnswerCapability(
          _rpcCapabilityDelegate,
          questionId,
          path,
        ),
  );

  // Owns every outgoing Call this connection sends — see
  // OutgoingCallCoordinator's own doc comment for why it's a standalone,
  // constructor-injected class rather than another private extension.
  // `late` for the same reason as [_rpcCapabilityDelegate]: the bound method
  // tear-offs below capture `this`.
  //
  // resolveLocalAnswer MUST stay a closure literal, not simplified to a
  // bare `_incomingCalls.resolveLocalAnswer` tear-off — see
  // [_incomingCalls]'s own doc comment for why: `late final` fields
  // evaluate lazily on first access, and _incomingCalls's own construction
  // eagerly reads `_outgoingCalls.startCallWithAllocatedQuestion`, so whichever field a caller
  // touches first (`_incomingCalls`, the common case — incoming Bootstrap/
  // Call messages are usually the first thing a server-role connection
  // handles) would otherwise force this field's initializer to read
  // _incomingCalls's value *while it's still being constructed*, which
  // throws. Deferring the read into a closure body means it never runs
  // until well after both fields have finished constructing.
  late final OutgoingCallCoordinator _outgoingCalls = OutgoingCallCoordinator(
    questions: _questionTable,
    imports: _importTable,
    sendBytes: _sendRaw,
    resolveParameterCapabilityDescriptors: _capabilityProtocol.resolveParameterCapabilityDescriptors,
    releaseParameterCapabilityExports:
        _capabilityProtocol.releaseParameterCapabilityExports,
    acquireCapabilityFromWireReference: _capabilityProtocol.acquireCapabilityFromWireReference,
    resolveLocalAnswer: (qid) => _incomingCalls.resolveLocalAnswer(qid),
    onReturn: _handleBootstrapReturn,
  );

  // Incoming Call handling: Bootstrap requests, promised-answer targets,
  // running a dispatch (with cancellation and tail-call support), and
  // building/sending its Return — see IncomingCallCoordinator's own doc
  // comment for why it's a standalone, constructor-injected class rather
  // than another private extension. `late` for the same reason as
  // [_rpcCapabilityDelegate]: the bound method tear-offs below capture `this`.
  //
  // startCallWithAllocatedQuestion is a bare tear-off (safe in either construction order,
  // unlike _outgoingCalls's resolveLocalAnswer above — see its comment):
  // OutgoingCallCoordinator's own construction never eagerly reads
  // anything back from this field, only building a deferred closure for
  // it, so forcing _outgoingCalls to construct here (if it hasn't
  // already) never reads this field's value while it's still being
  // assigned.
  late final IncomingCallCoordinator _incomingCalls = IncomingCallCoordinator(
    exportTable: _exportTable,
    answerTable: _answerTable,
    questions: _questionTable,
    sendBytes: _sendRaw,
    disposeIgnoringErrors: _disposeIgnoringErrors,
    isClosed: () => _closedError != null,
    tearDownConnection: (error) => _tearDown(error),
    tryExtractCapabilityReference:
        _capabilityProtocol.tryExtractCapabilityReference,
    acquireCapabilityFromWireReference: _capabilityProtocol.acquireCapabilityFromWireReference,
    exportResultCapabilityAsDescriptor: _capabilityProtocol.exportResultCapabilityAsDescriptor,
    startCallWithAllocatedQuestion: _outgoingCalls.startCallWithAllocatedQuestion,
    startParameterCapabilityDisposalTracking:
        (paramsCapabilities) => startParameterCapabilityDisposalTracking(
          _rpcCapabilityDelegate,
          paramsCapabilities,
          _decrementImportReference,
        ),
    finishParameterCapabilityDisposalTracking:
        finishParameterCapabilityDisposalTracking,
  );

  // Handles the bootstrap-specific half of a Return: distinguishing the
  // Bootstrap question's Return from a regular call's, resolving
  // [_bootstrapCompleter], and releasing the server's answer state for it.
  // Kept here (not in [OutgoingCallCoordinator]) because it reads/writes
  // [_bootstrapQuestionId]/[_bootstrapCompleter], state deliberately kept
  // out of [QuestionTable]/[ImportTable] — see their declarations above.
  // Invoked via [OutgoingCallCoordinator.onReturn], after it has already
  // confirmed a live completer exists for this Return's answerId.
  void _handleBootstrapReturn(RpcMessage msg) {
    if (msg.answerId != _bootstrapQuestionId) return;
    final bootstrapQid = _bootstrapQuestionId!;
    _bootstrapQuestionId = null;
    if (msg.isReturnResults && msg.capabilityTableReferences.isNotEmpty) {
      final importId = _capabilityProtocol.tryRetainImportIdFromWireReference(
        msg.capabilityTableReferences.first,
      );
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
          const RpcException('bootstrap Return had no capability in cap table'),
        );
      }
    }
    // Send Finish to release the server's answer state for this Bootstrap
    // question. releaseResultCaps=false because the client is retaining the
    // imported bootstrap capability.
    _sendRaw(buildFinishMessage(bootstrapQid, releaseResultCaps: false));
  }

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
  /// see [StreamingCallFlowController].
  ///
  /// [disembargoTimeout] bounds how long this vat waits for the peer's
  /// receiverLoopback reply to a Disembargo it sent (see
  /// [CapabilityProtocol.handleResolve]). Without a bound, a peer that
  /// never replies leaves the pipelined call
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
    int streamWindowSize = StreamingCallFlowController.defaultWindowSize,
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
    int streamWindowSize = StreamingCallFlowController.defaultWindowSize,
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
    // Unwrap first, like every ExportTable.retainOrCreateExportId caller — bootstrap
    // is registered as export 0 through the same ExportTable machinery, so
    // its identity must satisfy the same "always unwrapped" invariant those
    // rely on for deduplication (e.g. this same underlying capability being
    // handed back to ExportTable.retainOrCreateExportId again later, via a normal
    // export, must dedupe against this entry instead of creating a
    // redundant second export for it).
    final bootstrapIdentity = unwrapCapabilityLease(bootstrap);
    // See ExportTable.registerBootstrap's doc comment for why its remote
    // refcount starts at 0, not 1.
    conn._exportTable.registerBootstrap(bootstrapIdentity);
    // bootstrap's ownership transfers to this connection (see doc comment
    // above) — the entry just created its own ownedReference for
    // bootstrapIdentity, so if the caller passed an already-acquired lease
    // rather than a bare capability, that lease is now redundant with it
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

    _bootstrapCap = createImportedCapability(
      _rpcCapabilityDelegate,
      _bootstrapCompleter!.future,
    );
    return factory.fromCapability(_bootstrapCap!);
  }

  @override
  Future<void> close() async {
    if (_closedError != null) return;
    await _tearDown(null);
  }

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
        _incomingCalls.handleBootstrap(msg);
      case RpcMessageType.call:
        _incomingCalls.handleCall(msg);
      case RpcMessageType.return_:
        _outgoingCalls.handleReturn(msg);
      case RpcMessageType.resolve:
        _capabilityProtocol.handleResolve(msg);
      case RpcMessageType.finish:
        _incomingCalls.handleFinish(msg);
      case RpcMessageType.release:
        _capabilityProtocol.handleRelease(msg);
      case RpcMessageType.disembargo:
        _capabilityProtocol.handleDisembargo(msg);
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

    // Fail all pending questions, and reject any future outgoing Call.
    _outgoingCalls.tearDown(err);

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

  /// This connection's own [RpcCapabilityDelegate] — test-only, alongside
  /// [createImportedCapability]/[debugCreatePipelinedCapability]
  /// (see their doc comments, and issue #64): lets a test construct an RPC
  /// capability proxy that genuinely satisfies
  /// `identical(cap._delegate, _rpcCapabilityDelegate)` against a *real*
  /// connection (unlike `rpc_capability_test.dart`'s
  /// `FakeRpcCapabilityDelegate`, which only drives `rpc_capability.dart`
  /// in isolation). `CapabilityProtocol`'s own capTable-resolution side
  /// effects (export creation, refcount bumps) are independently
  /// unit-testable via a fake `tryExtractCapabilityReference` closure — see
  /// `capability_protocol_test.dart` — but this getter is still what lets
  /// `rpc_test.dart` reproduce the same scenario end-to-end against the
  /// real wiring (real `_ImportedCapability`, real `TwoPartyRpcConnection`),
  /// as a regression check that the wiring itself, not just the isolated
  /// logic, keeps behaving correctly.
  @visibleForTesting
  RpcCapabilityDelegate get debugRpcCapabilityDelegate =>
      _rpcCapabilityDelegate;

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
  /// wire (see [CapabilityProtocol.releaseImport] and its internal batched
  /// Release flush). Always zero between microtasks — it's only ever
  /// non-zero for the duration of a single, already-scheduled flush, and
  /// that flush clears it up front before it sends anything (so a
  /// mid-flush sink failure never leaves it non-empty either).
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

/// [TwoPartyRpcConnection]'s [RpcCapabilityDelegate] — see
/// [TwoPartyRpcConnection._rpcCapabilityDelegate]. Kept separate from
/// [TwoPartyRpcConnection] itself (rather than having the connection
/// `implements RpcCapabilityDelegate` directly) so wire-level entry points
/// like [startOutgoingCall]/[releaseImport] never become part of the
/// connection's own public API.
class _TwoPartyRpcCapabilityDelegate implements RpcCapabilityDelegate {
  final TwoPartyRpcConnection _conn;
  _TwoPartyRpcCapabilityDelegate(this._conn);

  @override
  ImportState getOrCreateImportState(int importId) =>
      _conn._importTable.getOrCreateState(importId);

  @override
  Future<void> releaseImport(int importId) =>
      _conn._capabilityProtocol.releaseImport(importId);

  @override
  StartedOutgoingCall startOutgoingCall({
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    List<Capability> paramsCapabilities = const [],
  }) => _conn._outgoingCalls.start(
    target: target,
    params: params,
    interfaceId: interfaceId,
    methodId: methodId,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  Future<ResolvedAnswer> resolveAnswer(int questionId) {
    final resolved = _conn._answerTable.resolvedFor(questionId);
    if (resolved != null) return Future.value(resolved);
    final pending = _conn._answerTable.pendingFor(questionId);
    if (pending != null) return pending;
    return Future.error(
      RpcException('invalid receiverAnswer questionId: $questionId'),
    );
  }

  @override
  int get streamWindowSize => _conn._streamWindowSize;
}
