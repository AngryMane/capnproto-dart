import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../rpc/rpc_exception.dart';
import 'rpc_payload.dart';

part 'dispatch.dart';
part 'dispatch_handle.dart';
part 'capability_handle.dart';
part 'capability_result.dart';
part 'deferred_capability.dart';

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
  /// carries the method arguments — see [RpcPayload].
  ///
  /// Returns a [DispatchResult] whose [DispatchResult.payload] contains the
  /// results struct, and [DispatchResult.caps] contains any capabilities
  /// returned by the method (in capTable order).
  ///
  /// Generated server base classes override this. The default implementation
  /// throws [RpcException].
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => Future.error(
    RpcException(
      'capability does not implement interface $interfaceId method $methodId',
      kind: ErrorKind.unimplemented,
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
    RpcPayload params, {
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
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
    DispatchContext? context,
  }) => dispatch(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  /// Optional hook for the tail-call wire optimization (see [TailCall]).
  ///
  /// Called before [dispatchWithContext] with the same arguments a normal
  /// dispatch would receive. Returning non-null means "don't run this
  /// dispatch at all — forward to [TailCall.target] instead". The default
  /// implementation returns null (never tail-calls), so existing
  /// implementations are unaffected.
  TailCall? tryTailCall(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => null;

  /// Dispatches a call and returns a [DispatchHandle] that allows creating
  /// pipelined result capabilities before the call completes.
  ///
  /// The default implementation delegates to [dispatch] and uses
  /// [DeferredCapability] for pipelining (local deferral, not wire-level).
  /// RPC-connected capabilities override this to return a wire-level pipelined
  /// capability via the `promisedAnswer` target.
  DispatchHandle dispatchForPipelining(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => _DeferredDispatchHandle(
    dispatchWithContext(
      interfaceId,
      methodId,
      params,
      paramsCapabilities: paramsCapabilities,
    ),
  );

  /// Zero-copy send path: [build] receives an [AnyPointerBuilder] to write
  /// params into directly, instead of the caller pre-building a standalone
  /// message first. [build] may append to [paramsCapabilities] as a side
  /// effect while it runs (for generic/typed fields whose capability list
  /// isn't known until build time) — implementations must only read
  /// [paramsCapabilities] after [build] returns, never before or during.
  ///
  /// [dispatch]/[dispatchWithContext] keep their existing [RpcPayload]-based
  /// signature unchanged — this is deliberately a separate, additive method
  /// rather than a signature change, so the *receiving* side (which already
  /// has fully-resolved params, per [RpcPayload]) never needs to round-trip
  /// through a build callback. Only the *calling* side benefits from this
  /// method, and only capabilities that actually have a better destination
  /// to offer (RPC-connected capabilities, building directly into the
  /// outgoing Call's envelope) need to override it.
  ///
  /// The default implementation is for local (non-networked) capabilities:
  /// it builds into its own standalone [MessageBuilder] and reads it back
  /// via a zero-copy builder→reader view (skipping even
  /// [MessageBuilder.serialize]'s framing step) before calling [dispatch].
  Future<DispatchResult> dispatchBuilding(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
    List<Capability> paramsCapabilities = const [],
  }) {
    final root = MessageBuilder().initAnyPointerRoot();
    build(root);
    return dispatch(
      interfaceId,
      methodId,
      RpcPayload.fromEnvelope(root.asReader()),
      paramsCapabilities: paramsCapabilities,
    );
  }

  /// Releases this capability reference and frees any associated resources.
  Future<void> dispose();
}

/// A non-owning reference to a [Capability] that does not keep it (or its
/// underlying RPC import/export state) alive, and does not require calling
/// [Capability.dispose] itself.
///
/// Useful for holding onto a capability a peer handed you as a long-lived
/// callback/observer (e.g. appended to a subscriber list) without that
/// reference alone forcing the capability to stay reachable, and without
/// creating an uncollectable cycle when the referent transitively holds a
/// strong reference back to whoever is holding this. [target] returns null
/// once the referenced capability has been garbage collected; the RPC
/// runtime's own dispose/release bookkeeping for it is unaffected either
/// way — this only changes whether *this reference* keeps it reachable.
final class WeakCapabilityRef<T extends Capability> {
  final WeakReference<T> _ref;

  WeakCapabilityRef(T capability) : _ref = WeakReference(capability);

  /// The referenced capability, or null if it has been garbage collected.
  T? get target => _ref.target;
}
