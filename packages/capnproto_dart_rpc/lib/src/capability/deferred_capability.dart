part of 'capability.dart';

class _DeferredDispatchHandle implements DispatchHandle {
  @override
  final Future<DispatchResult> result;
  _DeferredDispatchHandle(this.result);

  @override
  Capability pipelinedCapability(int ptrIndex) => DeferredCapability(
    result.then((r) => requireCapabilityFromResult(r, ptrIndex)),
  );

  @override
  Capability pipelinedCapabilityFromResultPath(List<int> path) =>
      DeferredCapability(
        result.then((r) => requireCapabilityFromResultPath(r, path)),
      );
}

/// A capability backed by a [Future] that resolves to the real capability.
///
/// Used as the fallback for [DispatchHandle.pipelinedCapability] when the underlying
/// [Capability] is not an RPC-connected imported cap and therefore cannot
/// send wire-level promisedAnswer messages.
class DeferredCapability extends Capability {
  final Future<Capability> _future;
  bool _disposed = false;
  Completer<void>? _disposeCompleter;
  Future<void>? _cleanupFuture;

  /// Creates a capability that defers to whatever [future] resolves to.
  DeferredCapability(Future<Capability> future) : _future = future {
    future.ignore();
  }

  /// The underlying promise used by the RPC layer when exporting this as a
  /// wire-level senderPromise.
  Future<Capability> get resolution => _future;

  Future<Capability> _resolveForCall() async {
    if (_disposed) {
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    final cap = await _future;
    if (_disposed) {
      // See dispose()'s matching comment on why this goes through
      // acquireCapabilityLease rather than disposing `cap` directly.
      await acquireCapabilityLease(cap).dispose();
      throw const RpcException(
        'capability is disposed',
        kind: ErrorKind.disconnected,
      );
    }
    return cap;
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final cap = await _resolveForCall();
    return cap.dispatch(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  Future<DispatchResult> dispatchWithContext(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
    DispatchCancellationContext? context,
  }) async {
    final cap = await _resolveForCall();
    return cap.dispatchWithContext(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
      context: context,
    );
  }

  @override
  Future<DispatchResult> dispatchWithParamsBuilder(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final cap = await _resolveForCall();
    return cap.dispatchWithParamsBuilder(
      interfaceId,
      methodId,
      build,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  DispatchHandle dispatchForPipelining(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return _DeferredDispatchHandle(
        Future<DispatchResult>.error(
          const RpcException(
            'capability is disposed',
            kind: ErrorKind.disconnected,
          ),
        ),
      );
    }
    return _DeferredDispatchHandle(
      _resolveForCall().then(
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
  Future<void> dispose() {
    final existing = _disposeCompleter;
    if (existing != null) return existing.future;
    _disposed = true;
    final completer = _disposeCompleter = Completer<void>();
    _startCleanup().then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  /// Stops waiting for this capability promise as part of external teardown.
  ///
  /// The eventual resolved capability is still released if [resolution]
  /// settles later, but current and future [dispose] calls complete
  /// immediately. This is used when the owner of a wire-level senderPromise
  /// has disconnected, so waiting for a promise that may depend on that
  /// connection can no longer make progress.
  void abandon() {
    _disposed = true;
    final completer = _disposeCompleter ??= Completer<void>();
    _startCleanup().ignore();
    if (!completer.isCompleted) completer.complete();
  }

  Future<void> _startCleanup() =>
      _cleanupFuture ??= () async {
        final cap = await _future.catchError(
          (_) => NullCapability() as Capability,
        );
        // Use a lease so independent references remain valid while this one is
        // released if the abandoned promise eventually resolves.
        await acquireCapabilityLease(cap).dispose();
      }();
}

/// A no-op capability used as a placeholder.
class NullCapability extends Capability {
  NullCapability();

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(const RpcException('null capability'));

  @override
  Future<void> dispose() async {}
}
