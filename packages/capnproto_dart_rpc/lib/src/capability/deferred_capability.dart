part of 'capability.dart';

class _DeferredCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  _DeferredCapCall(this.result);

  @override
  Capability pipelineResult(int ptrIndex) => DeferredCapability(
    result.then((r) => requireCapabilityFromResult(r, ptrIndex)),
  );

  @override
  Capability pipelineResultPath(List<int> path) => DeferredCapability(
    result.then((r) => requireCapabilityFromResultPath(r, path)),
  );
}

/// A capability backed by a [Future] that resolves to the real capability.
///
/// Used as the fallback for [CapCall.pipelineResult] when the underlying
/// [Capability] is not an RPC-connected imported cap and therefore cannot
/// send wire-level promisedAnswer messages.
class DeferredCapability extends Capability {
  final Future<Capability> _future;
  bool _disposed = false;
  Future<void>? _disposeFuture;

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
      // vendCapabilityHandle rather than disposing `cap` directly.
      await vendCapabilityHandle(cap).dispose();
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
    DispatchContext? context,
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
  Future<DispatchResult> dispatchBuilding(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final cap = await _resolveForCall();
    return cap.dispatchBuilding(
      interfaceId,
      methodId,
      build,
      paramsCapabilities: paramsCapabilities,
    );
  }

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return _DeferredCapCall(
        Future<DispatchResult>.error(
          const RpcException(
            'capability is disposed',
            kind: ErrorKind.disconnected,
          ),
        ),
      );
    }
    return _DeferredCapCall(
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
  Future<void> dispose() async {
    if (_disposed) return _disposeFuture ?? Future.value();
    _disposed = true;
    return _disposeFuture ??= () async {
      final cap = await _future.catchError(
        (_) => NullCapability() as Capability,
      );
      // Through vendCapabilityHandle, not `cap.dispose()` directly: the
      // resolved capability this DeferredCapability holds the only
      // *application*-visible reference to may still have an independent,
      // uncoordinated reference of its own elsewhere — e.g. the RPC layer
      // re-exporting it under a fresh export id once a senderPromise this
      // wraps resolves (see `CapabilityProtocol`'s internal
      // `_scheduleSenderPromiseResolve`), which is released separately and
      // shares no bookkeeping with this object at all. Disposing `cap`
      // directly would tear it down out from under that other reference
      // instead of just releasing this one's own share.
      await vendCapabilityHandle(cap).dispose();
    }();
  }
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
