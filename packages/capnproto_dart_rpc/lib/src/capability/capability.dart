import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../rpc/rpc_exception.dart';

final Future<void> _neverCanceledFuture = Completer<void>().future;

/// The result of a [Capability.dispatch] call.
///
/// [bytes] is a serialized Cap'n Proto message containing the method results.
/// [caps] contains any capabilities returned by the method, in capTable order.
///
/// Ownership of every capability in [caps] passes to the RPC runtime the
/// moment the `dispatch`/`dispatchWithContext` future resolves with this
/// result: from that point on, the implementation that returned it must not
/// dispose or otherwise assume continued ownership of them. The runtime
/// either exports them to the peer as part of the Return message, or — if
/// the answer is discarded before a Return can be sent (the connection
/// closed, or a Finish canceled it first) — disposes them itself.
class DispatchResult {
  final Uint8List bytes;
  final List<Capability> caps;
  DispatchResult({required this.bytes, this.caps = const []});

  /// Pre-built 16-byte message: single segment, null root pointer.
  /// Used as the result for `-> stream` and void methods.
  static final empty = DispatchResult(
    bytes: Uint8List.fromList([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  );
}

/// Cooperative cancellation state for an incoming dispatch.
///
/// Server implementations can check [isCanceled], await [canceled], or call
/// [throwIfCanceled] at await points to stop work after the caller sends
/// `Finish` or the connection closes.
class DispatchContext {
  static final DispatchContext neverCanceled = DispatchContext._never();

  final Completer<void>? _canceledCompleter;

  DispatchContext._() : _canceledCompleter = Completer<void>();
  DispatchContext._never() : _canceledCompleter = null;

  /// Whether the caller has abandoned this dispatch.
  bool get isCanceled => _canceledCompleter?.isCompleted ?? false;

  /// Completes when the caller abandons this dispatch.
  Future<void> get canceled =>
      _canceledCompleter?.future ?? _neverCanceledFuture;

  /// Throws [RpcException] if this dispatch has been canceled.
  void throwIfCanceled() {
    if (isCanceled) {
      throw const RpcException('dispatch canceled');
    }
  }

  void _cancel() {
    final completer = _canceledCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

/// Owns cancellation for a single incoming dispatch.
class DispatchCancellationController {
  final DispatchContext context = DispatchContext._();

  void cancel() => context._cancel();
}

/// Base class for all Cap'n Proto capabilities (remote object references).
///
/// A capability both designates an object and confers permission to call it.
///
/// **Server implementations** subclass this and override [dispatch] to handle
/// incoming method calls.
///
/// **Client stubs** (generated code) wrap a [Capability] to provide typed
/// methods. They delegate to [dispatch] on the underlying capability reference.
abstract class Capability {
  /// Dispatches an incoming method call.
  ///
  /// [interfaceId] and [methodId] identify the interface and method. [params]
  /// is a serialized Cap'n Proto message containing the method arguments.
  ///
  /// Returns a [DispatchResult] whose [DispatchResult.bytes] contains the
  /// serialized results struct, and [DispatchResult.caps] contains any
  /// capabilities returned by the method (in capTable order).
  ///
  /// Generated server base classes override this. The default implementation
  /// throws [RpcException].
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(
    RpcException(
      'capability does not implement interface $interfaceId method $methodId',
    ),
  );

  /// Dispatches a call to a `-> stream` method.
  ///
  /// Streaming methods always return the empty `StreamResult` struct, so
  /// there's nothing meaningful to return — this exists as a separate method
  /// (rather than just calling [dispatch] and discarding the result) so that
  /// RPC-connected capabilities can apply flow-control windowing: many
  /// streaming calls can be pipelined without unbounded buffering, instead
  /// of a full round-trip per call.
  ///
  /// The default implementation just awaits [dispatch], which is correct —
  /// per the Cap'n Proto spec, flow control is an optional optimization for
  /// `-> stream` methods, not a requirement for correctness. Only
  /// RPC-connected capabilities (see `TwoPartyRpcConnection`) override this
  /// with real windowing.
  Future<void> dispatchStreaming(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    await dispatch(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    );
  }

  /// Dispatches an incoming method call with cooperative cancellation state.
  ///
  /// Existing implementations may continue to override [dispatch]. Server
  /// implementations that want cancellation support can override this method
  /// and watch [context].
  Future<DispatchResult> dispatchWithContext(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
    DispatchContext? context,
  }) => dispatch(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  /// Starts a dispatch call and returns a [CapCall] that allows creating
  /// pipelined sub-capabilities before the round-trip completes.
  ///
  /// The default implementation delegates to [dispatch] and uses
  /// [DeferredCapability] for pipelining (local deferral, not wire-level).
  /// RPC-connected capabilities override this to return a wire-level pipelined
  /// capability via the `promisedAnswer` target.
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => _DeferredCapCall(
    dispatchWithContext(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    ),
  );

  /// Releases this capability reference and frees any associated resources.
  Future<void> dispose();
}

class _DeferredCapCall implements CapCall {
  @override
  final Future<DispatchResult> result;
  _DeferredCapCall(this.result);

  @override
  Capability pipelineResult(int ptrIndex) => DeferredCapability(
    result.then((r) => requireCapabilityFromResult(r, ptrIndex)),
  );
}

/// Resolves the capability at pointer slot [ptrIndex] of a [DispatchResult].
///
/// Deserializes [result.bytes], reads the [CapabilityPointer] at [ptrIndex] of
/// the root struct, and returns the corresponding entry from [result.caps].
/// Returns null when [ptrIndex] is out of range, the pointer is not a
/// [CapabilityPointer], the cap table index is out of range, or the result
/// bytes cannot be decoded.
///
/// Used by both [_DeferredCapCall] (local pipelining) and the RPC layer's
/// `_WirePipelinedCapability` (wire-level pipelining) so they share the same
/// pointer-slot → cap-table-index mapping logic.
Capability? capabilityFromResult(DispatchResult result, int ptrIndex) {
  try {
    return requireCapabilityFromResult(result, ptrIndex);
  } catch (_) {
    return null;
  }
}

/// Resolves the capability at pointer slot [ptrIndex], or throws an
/// [RpcException] that preserves why the pipeline target could not resolve.
///
/// Returns a vended handle (see [vendCapabilityHandle]), not the raw
/// [DispatchResult.caps] entry directly: the same underlying capability is
/// commonly reachable through more than one independent path from generated
/// code (e.g. an eagerly-pipelined `XxxPipeline.someCap` and the same field
/// read off the awaited `XxxPipeline.result` reader both resolve to the
/// identical [DispatchResult.caps] entry), and disposing one such reference
/// must not silently invalidate the other.
Capability requireCapabilityFromResult(DispatchResult result, int ptrIndex) {
  if (result.caps.isEmpty) {
    throw const RpcException('result has no capability table entries');
  }
  try {
    final root = MessageReader.deserialize(result.bytes).getRootRaw();
    if (ptrIndex < 0 || ptrIndex >= root.ptrWords) {
      throw RpcException('pointer slot $ptrIndex is out of range');
    }
    final ptr = WirePointer.decode(
      root.segment.data,
      root.ptrWordOffset + ptrIndex,
    );
    if (ptr is! CapabilityPointer) {
      throw RpcException(
        'pointer slot $ptrIndex in result struct is not a capability',
      );
    }
    final capIdx = ptr.capabilityIndex;
    if (capIdx >= result.caps.length) {
      throw RpcException(
        'capability table index $capIdx is out of range for ${result.caps.length} result capabilities',
      );
    }
    return vendCapabilityHandle(result.caps[capIdx]);
  } on RpcException {
    rethrow;
  } catch (e) {
    throw RpcException('failed to decode result capability: $e');
  }
}

// ---------------------------------------------------------------------------
// Reference-counted capability handles.
//
// A single resolved capability object (an entry in DispatchResult.caps, or
// equivalently the same entry read via a generated struct reader's
// interface-field getter) is often reachable through more than one
// independent path — see requireCapabilityFromResult's doc comment. Neither
// path "owns" the underlying object exclusively, so disposing through one of
// them must not invalidate the other. vendCapabilityHandle hands out a
// disposable proxy per call site, all sharing one refcount per underlying
// object (keyed by identity); the real object is only disposed once every
// vended handle for it has itself been disposed.
// ---------------------------------------------------------------------------

class _CapabilityRefCount {
  int count = 0;
  Future<void>? disposeFuture;
}

final Expando<_CapabilityRefCount> _capabilityRefCounts =
    Expando<_CapabilityRefCount>();

/// Returns a new disposable handle referencing [target], sharing reference
/// counting with every other handle vended for the same [target] instance
/// (by identity). [target] itself is only disposed once every handle vended
/// for it has been disposed.
Capability vendCapabilityHandle(Capability target) {
  final refCount = _capabilityRefCounts[target] ??= _CapabilityRefCount();
  return _CapabilityHandle(target, refCount);
}

class _CapabilityHandle extends Capability {
  final Capability _target;
  final _CapabilityRefCount _refCount;
  bool _handleDisposed = false;

  _CapabilityHandle(this._target, this._refCount) {
    _refCount.count++;
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.dispatch(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  Future<void> dispatchStreaming(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.dispatchStreaming(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  Future<DispatchResult> dispatchWithContext(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
    DispatchContext? context,
  }) => _target.dispatchWithContext(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
    context: context,
  );

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.beginDispatch(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  Future<void> dispose() async {
    if (_handleDisposed) return;
    _handleDisposed = true;
    _refCount.count--;
    if (_refCount.count <= 0) {
      await (_refCount.disposeFuture ??= _target.dispose());
    }
  }
}

/// Represents an in-progress dispatch call.
///
/// Returned by [Capability.beginDispatch]. Carries the result future and a
/// factory for creating a capability that pipelines onto the result's caps
/// without waiting for the round-trip to complete.
abstract interface class CapCall {
  /// The eventual result of the dispatched call.
  Future<DispatchResult> get result;

  /// Returns a capability that targets pointer field [ptrIndex] of the result
  /// struct's capTable — usable immediately, before [result] completes.
  Capability pipelineResult(int ptrIndex);
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

  DeferredCapability(Future<Capability> future) : _future = future {
    future.ignore();
  }

  /// The underlying promise used by the RPC layer when exporting this as a
  /// wire-level senderPromise.
  Future<Capability> get resolution => _future;

  Future<Capability> _resolveForCall() async {
    if (_disposed) {
      throw const RpcException('capability is disposed');
    }
    final cap = await _future;
    if (_disposed) {
      await cap.dispose();
      throw const RpcException('capability is disposed');
    }
    return cap;
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
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
    Uint8List params, {
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
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_disposed) {
      return _DeferredCapCall(
        Future<DispatchResult>.error(
          const RpcException('capability is disposed'),
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
      await cap.dispose();
    }();
  }
}

/// Backward-compatible alias for [DeferredCapability].
typedef PipelinedCapability = DeferredCapability;

/// A no-op capability used as a placeholder.
class NullCapability extends Capability {
  NullCapability();

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(const RpcException('null capability'));

  @override
  Future<void> dispose() async {}
}
