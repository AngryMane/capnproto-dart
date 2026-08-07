part of 'capability.dart';

final Future<void> _neverCanceledFuture = Completer<void>().future;

/// The result of a [Capability.dispatch] call.
///
/// [payload] is the method results — either a freshly-built standalone
/// message, or (for a networked call) a live view into the received Return
/// envelope. See [RpcPayload]. [caps] contains any capabilities returned by
/// the method, in capTable order.
///
/// Ownership of every capability in [caps] passes to the RPC runtime the
/// moment the `dispatch`/`dispatchWithContext` future resolves with this
/// result: from that point on, the implementation that returned it must not
/// dispose or otherwise assume continued ownership of them. The runtime
/// either exports them to the peer as part of the Return message, or — if
/// the answer is discarded before a Return can be sent (the connection
/// closed, or a Finish canceled it first) — disposes them itself.
///
/// This applies equally whether an entry is a bare capability or a
/// [CapabilityLease] (e.g. one read out of another call's own
/// result via [requireCapabilityFromResult] and forwarded here) — the
/// runtime unwraps it to decide what to export, and disposes the lease you
/// handed it once that export is established (see `CapabilityProtocol`'s
/// `exportResultCapabilityAsWireReference`/internal
/// `_createWireReferenceForResolvedCapability`).
/// Reusing that same lease — or the bare capability it wrapped — for anything *after* returning it here is a
/// use-after-ownership-transfer bug: if every reference to the underlying
/// capability happens to have been released by then, [acquireCapabilityLease]
/// catches the reuse itself rather than silently returning a lease for
/// an already-torn-down object.
class DispatchResult {
  /// The method results — see [RpcPayload].
  final RpcPayload payload;

  /// Capabilities returned by the method, in capTable order.
  final List<Capability> caps;

  /// Creates a dispatch result wrapping [payload], with any returned
  /// capabilities in [caps].
  DispatchResult({required this.payload, this.caps = const []});

  /// Pre-built 16-byte message: single segment, null root pointer.
  /// Used as the result for `-> stream` and void methods.
  static final empty = DispatchResult(
    payload: RpcPayload.fromBytes(
      Uint8List.fromList([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ),
  );
}

/// Builds a [DispatchResult] by initializing [factory]'s root in a fresh
/// [MessageBuilder] and handing it to [build]. Covers the common RPC-server
/// case of returning a freshly-built, standalone results struct — see
/// [RpcPayload.fromBuilder] for why the builder is wrapped directly rather
/// than serialized. [caps] is forwarded to [DispatchResult.caps] unchanged,
/// for methods that return capabilities (see generated `set<Field>(index)`
/// calls, whose index must match [caps]'s order).
DispatchResult
buildDispatchResult<R extends StructReader, B extends StructBuilder>(
  StructFactory<R, B> factory,
  void Function(B results) build, {
  List<Capability> caps = const [],
}) {
  final results = MessageBuilder().initRoot(factory);
  build(results);
  return DispatchResult(payload: RpcPayload.fromBuilder(results), caps: caps);
}

/// Describes a request to perform a tail call: the entire result of the
/// current dispatch should be exactly the result of calling [target]'s [interfaceId]/[methodId]
/// method with [params]/[paramsCapabilities].
///
/// This is a declarative request consumed by the RPC runtime, not a protocol
/// wire message or an in-progress call.
///
/// Returned by [Capability.tryTailCall]. When [target] is a capability
/// imported from the same peer connection that is asking for the current
/// dispatch, RPC-connected capabilities apply the Cap'n Proto Level 1 tail
/// call wire optimization (`Call.sendResultsTo=yourself` /
/// `Return.takeFromOtherQuestion`), avoiding an extra network round trip.
/// Otherwise this is a transparent pass-through with no special wire
/// behavior — semantically identical, just without the optimization.
class TailCallRequest {
  /// The capability the current dispatch's result should be taken from.
  final Capability target;

  /// The interface id to call on [target].
  final int interfaceId;

  /// The method id to call on [target].
  final int methodId;

  /// The params to pass to [target]'s method.
  final RpcPayload params;

  /// Capabilities referenced by [params], in capTable order.
  final List<Capability> paramsCapabilities;

  /// Creates a tail-call request describing a dispatch to [target]'s
  /// [interfaceId]/[methodId] method with [params]/[paramsCapabilities].
  const TailCallRequest(
    this.target,
    this.interfaceId,
    this.methodId,
    this.params, {
    this.paramsCapabilities = const [],
  });
}

/// Cooperative cancellation state for an incoming dispatch.
///
/// Server implementations can check [isCanceled], await [canceled], or call
/// [throwIfCanceled] at await points to stop work after the caller sends
/// `Finish` or the connection closes.
class DispatchCancellationContext {
  /// A context that never reports cancellation — for dispatch paths that
  /// don't track it.
  static final DispatchCancellationContext neverCanceled = DispatchCancellationContext._never();

  final Completer<void>? _canceledCompleter;

  DispatchCancellationContext._() : _canceledCompleter = Completer<void>();
  DispatchCancellationContext._never() : _canceledCompleter = null;

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
  final DispatchCancellationContext context = DispatchCancellationContext._();

  void cancel() => context._cancel();
}
