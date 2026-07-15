import 'dart:typed_data';

import '../rpc/rpc_exception.dart';

/// The result of a [Capability.dispatch] call.
///
/// [bytes] is a serialized Cap'n Proto message containing the method results.
/// [caps] contains any capabilities returned by the method, in capTable order.
class DispatchResult {
  final Uint8List bytes;
  final List<Capability> caps;
  DispatchResult({required this.bytes, this.caps = const []});

  /// Pre-built 16-byte message: single segment, null root pointer.
  /// Used as the result for `-> stream` and void methods.
  static final empty = DispatchResult(
    bytes: Uint8List.fromList(
        [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  );
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
  }) =>
      Future.error(RpcException(
          'capability does not implement interface $interfaceId method $methodId'));

  /// Releases this capability reference and frees any associated resources.
  Future<void> dispose();
}

/// A capability backed by a [Future] that resolves to the real capability.
///
/// Used for promise pipelining: generated client stubs return a
/// [PipelinedCapability] immediately when calling a method that returns a
/// capability, without waiting for the RPC round-trip.
class PipelinedCapability extends Capability {
  final Future<Capability> _future;

  PipelinedCapability(Future<Capability> future) : _future = future {
    future.ignore();
  }

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    final cap = await _future;
    return cap.dispatch(interfaceId, methodId, params,
        paramsCapabilities: paramsCapabilities);
  }

  @override
  Future<void> dispose() async {
    final cap = await _future.catchError((_) => NullCapability() as Capability);
    await cap.dispose();
  }
}

/// A no-op capability used as a placeholder.
class NullCapability extends Capability {
  NullCapability();

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    Uint8List params, {
    List<Capability> paramsCapabilities = const [],
  }) =>
      Future.error(const RpcException('null capability'));

  @override
  Future<void> dispose() async {}
}
