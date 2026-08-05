import 'dart:async';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:meta/meta.dart';

import '../../capability/capability.dart';
import '../../capability/rpc_payload.dart';
import '../flow_controller.dart';
import '../rpc_exception.dart';
import 'import_table.dart';
import 'wire_capability_context.dart';

/// The single point of contact the owning connection uses to construct,
/// classify, and manage the lifecycle of every wire-backed capability
/// (`_ImportedCapability`/`_WirePipelinedCapability`/
/// `_ReceiverAnswerCapability`/`_ParamCapsReleaseTracker` below) it vends —
/// so `two_party_connection.dart` itself never needs to name any of those
/// private types directly. One instance per connection, bound to that
/// connection's own [WireCapabilityContext] for its whole lifetime.
///
/// This exists specifically so `two_party_connection.dart` can stop being
/// `part of` the same library as this file: without it, the connection's own
/// wiring code would need to `cap is _ImportedCapability`, read
/// `cap._cachedState`, write `cap._deferredReleaseSink`, etc. directly,
/// which only compiles when both files are `part of` the same library. Every
/// method here is a plain, `Capability`/[WireCapabilityKind]-typed public
/// surface instead.
final class WireCapabilityRuntime {
  /// This runtime's connection, threaded through to every capability it
  /// constructs and used as the identity anchor for [classify]/
  /// [beginParamCapsRelease]'s "does this capability belong to this
  /// connection" checks — see [WireCapabilityKind]'s own doc comment for why
  /// that must be an `identical()` check, not `==`.
  final WireCapabilityContext context;

  /// Decrements a same-connection import's local refcount once a params
  /// capability wrapping it is disposed during [beginParamCapsRelease]'s
  /// deferred-release window — see that method's own doc comment.
  final void Function(int importId) decrementImportReference;

  WireCapabilityRuntime({
    required this.context,
    required this.decrementImportReference,
  });

  /// Builds the [Capability] proxying a remote capability whose import id
  /// isn't known synchronously yet (the client-side bootstrap capability,
  /// before the handshake resolves — see `TwoPartyRpcConnection.bootstrap`).
  Capability createImported(Future<int> importIdFuture) =>
      _ImportedCapability(context, importIdFuture);

  /// As [createImported], for an import whose [ImportState] is already
  /// known — see `CapabilityProtocol.capabilityFromDescriptor`'s
  /// senderHosted/senderPromise branches, the only real caller.
  Capability createImportedFromState(ImportState state) =>
      _ImportedCapability.fromState(context, state);

  /// Builds the [Capability] a `receiverAnswer` capTable entry resolves to
  /// — see `CapabilityProtocol.capabilityFromDescriptor`'s receiverAnswer
  /// branch.
  Capability createReceiverAnswer(int questionId, List<int> path) =>
      _ReceiverAnswerCapability(context, questionId, path);

  /// Classifies [capability] as wire-hosted or not — see
  /// [WireCapabilityKind]'s doc comment. `_WirePipelinedCapability` is never
  /// constructed outside this file (only `_WireCapCall`/`_AsyncWireCapCall`,
  /// below, do), so unlike [createImported]/[createReceiverAnswer] it has no
  /// matching `create*` method here.
  WireCapabilityKind classify(Capability capability) {
    if (capability is _ImportedCapability &&
        identical(capability._conn, context)) {
      return ImportedWireCapability(
        capability._cachedState?.importId ?? capability._importIdFuture,
      );
    }
    if (capability is _WirePipelinedCapability &&
        identical(capability._conn, context)) {
      return PipelinedWireCapability(
        hasResolved: capability._hasResolved,
        parentQuestionId: capability._parentQid,
        transformPath: capability._transformPath,
      );
    }
    return const NotWireCapability();
  }

  /// Starts a deferred-release tracking window for whichever of
  /// [paramsCapabilities] are same-connection `_ImportedCapability`
  /// wrappers freshly imported for a call — see
  /// `IncomingCallCoordinator._runDispatch`'s own doc comment for why.
  /// Returns an opaque ticket (`null` if there's nothing to track) to pass
  /// back to [finalizeParamCapsRelease] once the call settles; opaque
  /// because the caller has no legitimate use for anything about it besides
  /// handing it back unchanged.
  Object? beginParamCapsRelease(List<Capability> paramsCapabilities) {
    final wrappers = paramsCapabilities
        .whereType<_ImportedCapability>()
        .where((c) => identical(c._conn, context))
        .toList(growable: false);
    if (wrappers.isEmpty) return null;
    final tracker = _ParamCapsReleaseTracker(wrappers);
    for (final wrapper in wrappers) {
      wrapper._deferredReleaseSink = (id) {
        decrementImportReference(id);
        tracker.disposedImportIds.add(id);
      };
    }
    return tracker;
  }

  /// Ends [ticket]'s deferred-release window (a no-op, reporting
  /// `allDisposed` true, for a null ticket — no capability params means
  /// nothing to release) and reports two independent things: `allDisposed`
  /// decides `Return.releaseParamCaps` directly (`true` when every params
  /// capability freshly imported for the call was disposed before it
  /// settled — their wire Release was already folded into the refcount
  /// decrement done by [_ImportedCapability]'s deferred sink, so none needs
  /// sending); `explicitReleaseIds` is exactly the import ids that were
  /// disposed but still need their own wire Release sent — only ever
  /// non-empty when `allDisposed` is `false`, and can legitimately be
  /// *empty even when `allDisposed` is `false`* (nothing disposed yet at
  /// all). A named record, not a positional one: naming positional record
  /// fields in a type signature is purely cosmetic in Dart (it doesn't
  /// create real `.allDisposed`/`.explicitReleaseIds` getters, only
  /// `.$1`/`.$2`), so a genuinely named record is what actually keeps the
  /// two from being collapsed into one ambiguous empty list at the call
  /// site. Either way, clears each wrapper's sink so a *later* dispose() of
  /// one that's still outstanding goes through the normal (non-deferred)
  /// [WireCapabilityContext.releaseImport] path.
  ({bool allDisposed, List<int> explicitReleaseIds}) finalizeParamCapsRelease(
    Object? ticket,
  ) {
    final tracker = ticket as _ParamCapsReleaseTracker?;
    if (tracker == null) {
      return (allDisposed: true, explicitReleaseIds: const []);
    }
    for (final wrapper in tracker.wrappers) {
      wrapper._deferredReleaseSink = null;
    }
    if (tracker.disposedImportIds.length == tracker.wrappers.length) {
      return (allDisposed: true, explicitReleaseIds: const []);
    }
    return (
      allDisposed: false,
      explicitReleaseIds: tracker.disposedImportIds.toList(growable: false),
    );
  }
}

/// Tracks a single `IncomingCallCoordinator._runDispatch` call's params-caps
/// deferred-release window — see that class's own
/// `_finalizeParamCapsTracker`/`beginParamCapsRelease`/`finalizeParamCapsRelease`.
/// [wrappers] are every freshly-imported `_ImportedCapability` created for
/// this call's params (one per senderHosted/senderPromise capTable entry);
/// [disposedImportIds] accumulates the import ID each time one of them is
/// disposed while the window is open (see [_ImportedCapability]'s
/// `_deferredReleaseSink`) — as a `List`, not a `Set`, so a duplicate
/// import ID appearing more than once among the params (two distinct
/// wrapper objects for the same underlying capability) is still counted
/// once per wrapper, matching the refcount contribution each one made.
class _ParamCapsReleaseTracker {
  final List<_ImportedCapability> wrappers;
  final List<int> disposedImportIds = [];
  _ParamCapsReleaseTracker(this.wrappers);
}

// ---------------------------------------------------------------------------
// _ImportedCapability: client-side proxy for a remote capability
// ---------------------------------------------------------------------------

class _ImportedCapability extends Capability {
  final WireCapabilityContext _conn;
  bool _disposed = false;

  // Set only for a call's freshly-imported params capabilities (see
  // _runDispatch/_ParamCapsReleaseTracker), for the window between dispatch
  // starting and its Return being sent. While set, dispose() defers the
  // wire Release entirely to the tracker instead of sending one itself, so
  // the connection can fold it into `Return.releaseParamCaps` when every
  // params capability created for the call turns out to have been disposed
  // by the time the call settles. Cleared once that window ends (Return
  // sent), so a dispose() after that point behaves exactly as normal.
  void Function(int importId)? _deferredReleaseSink;

  // Resolves to the import ID once the bootstrap handshake completes.
  final Future<int> _importIdFuture;
  final Future<ImportState>? _stateFuture;
  ImportState? _cachedState;

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

  _ImportedCapability.fromState(this._conn, ImportState state)
    : _importIdFuture = Future.value(state.importId),
      _stateFuture = Future.value(state),
      _cachedState = state {
    _importIdFuture.ignore();
  }

  Future<ImportState> get _state async {
    final cached = _cachedState;
    if (cached != null) return cached;
    final stateFuture = _stateFuture;
    if (stateFuture != null) {
      final state = await stateFuture;
      _cachedState = state;
      return state;
    }
    final state = _conn.importStateFor(await _importIdFuture);
    _cachedState = state;
    return state;
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    // `_cachedState ?? await _state` skips `_state`'s own `await` entirely
    // when the state is already cached — Dart's `await` costs at least one
    // microtask tick even for an already-completed Future, and this is the
    // common case for every call after the first through a resolved import.
    final state = _cachedState ?? await _state;
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
    // state.importId is already known synchronously here (whether from
    // cache or from the await above), so this always goes through
    // TwoPartyRpcConnection's synchronous fast path (ImportedCapabilityTarget
    // holds it directly, no Future wrapping/await indirection needed).
    final started = _conn.startOutgoingCall(
      target: ImportedCapabilityTarget(state.importId),
      params: BuilderParams(
        (anyPtr) => anyPtr.setMessageBytes(
          params.bytes,
          preserveCapabilityPointers: true,
        ),
      ),
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    return started.result;
  }

  @override
  Future<DispatchResult> dispatchBuilding(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    // See dispatch() for why this skips _state's own await when cached.
    final state = _cachedState ?? await _state;
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final replacement = state.replacement;
    if (replacement != null) {
      return replacement.dispatchBuilding(
        interfaceId,
        methodId,
        build,
        paramsCapabilities: paramsCapabilities,
      );
    }
    final error = state.error;
    if (error != null) {
      return Future<DispatchResult>.error(error, state.stackTrace);
    }
    state.receivedCall = true;
    // See dispatch()'s equivalent line for why this always takes the fast
    // path now that state.importId is known.
    final started = _conn.startOutgoingCall(
      target: ImportedCapabilityTarget(state.importId),
      params: BuilderParams(build),
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    return started.result;
  }

  @override
  Future<void> dispatchStreaming(
    int interfaceId,
    int methodId,
    RpcPayload params, {
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
    final paramsBytes = params.bytes;
    final started = _conn.startOutgoingCall(
      target: ImportedCapabilityTarget(state.importId),
      params: SerializedParams(paramsBytes),
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    final controller =
        _flowController ??= FlowController(windowSize: _conn.streamWindowSize);
    return controller.send(paramsBytes.lengthInBytes, started.result);
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
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
      final started = _conn.startOutgoingCall(
        target: ImportedCapabilityTarget(cached.importId),
        params: SerializedParams(params.bytes),
        interfaceId: interfaceId,
        methodId: methodId,
        paramsCapabilities: paramsCapabilities,
      );
      return _WireCapCall(started.result, _conn, started.questionId);
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
          final started = _conn.startOutgoingCall(
            target: ImportedCapabilityTarget(state.importId),
            params: SerializedParams(params.bytes),
            interfaceId: interfaceId,
            methodId: methodId,
            paramsCapabilities: paramsCapabilities,
          );
          if (!qidCompleter.isCompleted) {
            qidCompleter.complete(started.questionId);
          }
          return started.result;
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
    if (id < 0) return;
    final sink = _deferredReleaseSink;
    if (sink != null) {
      sink(id);
      return;
    }
    await _conn.releaseImport(id);
  }
}

// ---------------------------------------------------------------------------
// _WireCapCall: CapCall backed by a pending question on the wire
// ---------------------------------------------------------------------------

class _WireCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  final WireCapabilityContext _conn;
  final int _qid;

  _WireCapCall(this.result, this._conn, this._qid);

  @override
  Capability pipelineResult(int ptrIndex) =>
      _WirePipelinedCapability(_conn, _qid, [ptrIndex], result);

  @override
  Capability pipelineResultPath(List<int> path) =>
      _WirePipelinedCapability(_conn, _qid, path, result);
}

class _AsyncWireCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  final WireCapabilityContext _conn;
  final Future<int> _qidFuture;

  _AsyncWireCapCall(this.result, this._conn, this._qidFuture);

  @override
  Capability pipelineResult(int ptrIndex) => pipelineResultPath([ptrIndex]);

  @override
  Capability pipelineResultPath(List<int> path) => DeferredCapability(() async {
    final qid = await _qidFuture;
    if (qid >= 0) {
      return _WirePipelinedCapability(_conn, qid, path, result);
    }
    final resolved = await result;
    return requireCapabilityFromResultPath(resolved, path);
  }());
}

// ---------------------------------------------------------------------------
// _WirePipelinedCapability: targets a promisedAnswer on the wire, then
// switches to the resolved imported capability once the parent completes.
// ---------------------------------------------------------------------------

class _WirePipelinedCapability extends Capability {
  final WireCapabilityContext _conn;
  final int _parentQid;
  // The full getPointerField hop sequence into the parent answer (see
  // RpcCapDescriptor.path) — today always a single index, since nothing
  // generates a deeper path yet (see _collectCapResults in
  // dart_generator.dart), but represented as a path throughout the wire
  // codec and resolution layers, so this doesn't have to special-case
  // length-1 vs. longer paths.
  final List<int> _transformPath;
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
    this._transformPath,
    Future<DispatchResult> parentResult,
  ) {
    _resolution = parentResult.then(
      (result) => requireCapabilityFromResultPath(result, _transformPath),
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
    RpcPayload params, {
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
    final started = _conn.startOutgoingCall(
      target: PromisedAnswerTarget(_parentQid, transformPath: _transformPath),
      params: SerializedParams(params.bytes),
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    return _trackPipelinedCall(started.result);
  }

  @override
  Future<DispatchResult> dispatchBuilding(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
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
      return r.dispatchBuilding(
        interfaceId,
        methodId,
        build,
        paramsCapabilities: paramsCapabilities,
      );
    }
    final resolutionError = _resolutionError;
    if (resolutionError != null) {
      return Future.error(resolutionError, _resolutionStackTrace);
    }
    final started = _conn.startOutgoingCall(
      target: PromisedAnswerTarget(_parentQid, transformPath: _transformPath),
      params: BuilderParams(build),
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    return _trackPipelinedCall(started.result);
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
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
    final started = _conn.startOutgoingCall(
      target: PromisedAnswerTarget(_parentQid, transformPath: _transformPath),
      params: SerializedParams(params.bytes),
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    return _WireCapCall(
      _trackPipelinedCall(started.result),
      _conn,
      started.questionId,
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _disposeResolvedIfIdle();
  }
}

class _ReceiverAnswerCapability extends Capability {
  final WireCapabilityContext _conn;
  final int _questionId;
  final List<int> _path;
  bool _disposed = false;

  // Resolved (and vended — see requireCapabilityFromResultPath) at most
  // once and cached, mirroring _WirePipelinedCapability: this capability
  // can be dispatched through multiple times before it's disposed (e.g.
  // several pipelined calls against the same receiverAnswer target), and
  // each of those calls must reuse the same resolved handle rather than
  // vending — and then never disposing — a fresh one every time, which
  // would permanently pin the underlying identity's shared refcount by one
  // for every call ever made through this capability.
  Future<Capability>? _resolution;

  // Tracks every dispatch()/dispatchBuilding()/beginDispatch() call that was
  // admitted (started before _disposed flipped true), mirroring
  // _WirePipelinedCapability's _pendingPipelinedCalls — but, unlike that
  // class (which only tracks calls made *before* its target resolves, since
  // afterwards it dispatches directly against the already-resolved
  // capability with no tracking at all), every call through this class goes
  // through _resolve() and is tracked, since there's no untracked
  // "already resolved, dispatch directly" fast path here. Without this,
  // dispose() could release the shared resolved handle — tearing down its
  // real target — while one of these calls was still using it.
  int _pendingCalls = 0;
  Future<void>? _resolvedDisposeFuture;

  // dispose()'s own returned Future must not complete until the real
  // underlying disposal has itself finished — not just been scheduled —
  // per Capability.dispose()'s own doc comment ("frees any associated
  // resources"). When dispose() is called while calls are still pending,
  // that real disposal is deferred (see _trackCall/_disposeResolvedIfIdle)
  // until they drain; this completer is what lets dispose()'s Future wait
  // for that deferred point instead of resolving early, whether the real
  // disposal happens synchronously (right away, if already idle) or only
  // once the last pending call finishes.
  Completer<void>? _disposeCompleter;

  _ReceiverAnswerCapability(this._conn, this._questionId, this._path);

  Future<Capability> _resolve() => _resolution ??= _resolveOnce();

  Future<Capability> _resolveOnce() async {
    final answer = await _conn.resolveAnswer(_questionId);
    return requireCapabilityFromResultPath(
      DispatchResult(
        payload: RpcPayload.fromBytes(answer.resultBytes),
        caps: answer.caps,
      ),
      _path,
    );
  }

  Future<T> _trackCall<T>(Future<T> future) {
    _pendingCalls++;
    future.whenComplete(() {
      _pendingCalls--;
      if (_disposed) {
        _disposeResolvedIfIdle().ignore();
      }
    }).ignore();
    return future;
  }

  Future<void> _disposeResolvedIfIdle() {
    if (!_disposed || _pendingCalls > 0) {
      return Future.value();
    }
    final resolution = _resolution;
    if (resolution == null) {
      // Never dispatched through, so there was never anything to resolve
      // (or dispose) in the first place — this is itself the terminal
      // outcome dispose() is waiting on.
      _disposeCompleter?.complete();
      return Future.value();
    }
    final existing = _resolvedDisposeFuture;
    if (existing != null) return existing;
    // A resolution that failed (e.g. an invalid questionId — see
    // _resolveOnce) never produced a handle in the first place, so there's
    // nothing to dispose — swallow that here the same way the previous
    // (untracked) implementation's try/catch did. Note this `onError` only
    // ever fires for `resolution`'s own failure, per Future.then's
    // documented semantics — a failure from the `cap.dispose()` call below
    // is a completely separate failure of `future` itself (propagated to
    // dispose()'s own caller below), not something this `onError` ever
    // observes or swallows.
    final future = resolution.then(
      (cap) => cap.dispose(),
      onError: (Object error, StackTrace stackTrace) {},
    );
    _resolvedDisposeFuture = future;
    // Deliberately `.then(onValue, onError:)`, not `.whenComplete(...)`:
    // whenComplete's callback runs on both success and failure alike but
    // can't distinguish which happened, so unconditionally calling
    // `complete()` from it would report the resolved target's own real
    // dispose() failure (if `future` itself rejects) as a success to
    // dispose()'s caller — silently discarding it, contrary to
    // Capability.dispose()'s own doc comment ("frees any associated
    // resources"). Forwarding the actual outcome here instead means a
    // failure the resolved target's dispose() raises is a failure
    // `receiverAnswerCap.dispose()` itself raises too.
    future
        .then<void>(
          (_) {
            final completer = _disposeCompleter;
            if (completer != null && !completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            final completer = _disposeCompleter;
            if (completer != null && !completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
        )
        .ignore();
    return future;
  }

  static RpcException get _disposedError => const RpcException(
    'capability is disposed',
    kind: ErrorKind.disconnected,
  );

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) return Future.error(_disposedError);
    return _trackCall(
      _resolve().then(
        (cap) => cap.dispatch(
          interfaceId,
          methodId,
          params,
          paramsCapabilities: paramsCapabilities,
        ),
      ),
    );
  }

  @override
  Future<DispatchResult> dispatchBuilding(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) return Future.error(_disposedError);
    return _trackCall(
      _resolve().then(
        (cap) => cap.dispatchBuilding(
          interfaceId,
          methodId,
          build,
          paramsCapabilities: paramsCapabilities,
        ),
      ),
    );
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) return _ErrorCapCall(_disposedError);
    final result = _trackCall(
      _resolve().then(
        (cap) => cap.dispatch(
          interfaceId,
          methodId,
          params,
          paramsCapabilities: paramsCapabilities,
        ),
      ),
    );
    result.ignore();
    return _FutureCapCall(result);
  }

  @override
  Future<void> dispose() {
    final existing = _disposeCompleter;
    if (existing != null) return existing.future;
    _disposed = true;
    _disposeCompleter = Completer<void>();
    // Kicks off (or, if calls are still pending, merely checks — see
    // _trackCall for what actually triggers it once they drain) the real
    // disposal; _disposeCompleter (via _disposeResolvedIfIdle's own hooks)
    // is what makes the Future returned below wait for that to actually
    // finish rather than resolving as soon as this synchronous call returns.
    _disposeResolvedIfIdle().ignore();
    return _disposeCompleter!.future;
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

  @override
  Capability pipelineResultPath(List<int> path) => DeferredCapability(
    result.then((r) => requireCapabilityFromResultPath(r, path)),
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

  @override
  Capability pipelineResultPath(List<int> path) => DeferredCapability(
    result.then((r) => requireCapabilityFromResultPath(r, path)),
  );
}

// ---------------------------------------------------------------------------
// Test-only construction seams (see issue #64): each wire capability class
// above depends only on [WireCapabilityContext], so its dispatch/dispose
// logic can be driven by a fake implementation of that interface instead of
// a real [TwoPartyRpcConnection]/socket pair. These just expose the
// otherwise-private constructors for that purpose, behind the public
// [Capability] surface every caller already uses.
// ---------------------------------------------------------------------------

/// Builds the [Capability] a peer's `senderHosted`/`senderPromise` capTable
/// entry resolves to (see [CapabilityProtocol.capabilityFromDescriptor]),
/// bound to [context] instead of a real connection.
@visibleForTesting
Capability debugCreateImportedCapability(
  WireCapabilityContext context,
  Future<int> importIdFuture,
) => _ImportedCapability(context, importIdFuture);

/// As [debugCreateImportedCapability], for an import whose [ImportState] is
/// already known.
@visibleForTesting
Capability debugCreateImportedCapabilityFromState(
  WireCapabilityContext context,
  ImportState state,
) => _ImportedCapability.fromState(context, state);

/// Builds the [Capability] a `promisedAnswer`/pipelined call target resolves
/// to (see [_WireCapCall.pipelineResult]), bound to [context] instead of a
/// real connection.
@visibleForTesting
Capability debugCreateWirePipelinedCapability(
  WireCapabilityContext context,
  int parentQid,
  List<int> transformPath,
  Future<DispatchResult> parentResult,
) => _WirePipelinedCapability(context, parentQid, transformPath, parentResult);

/// Builds the [Capability] a `receiverAnswer` capTable entry resolves to
/// (see [CapabilityProtocol.capabilityFromDescriptor]), bound to
/// [context] instead of a real connection.
@visibleForTesting
Capability debugCreateReceiverAnswerCapability(
  WireCapabilityContext context,
  int questionId,
  List<int> path,
) => _ReceiverAnswerCapability(context, questionId, path);
