import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../rpc/rpc_exception.dart';
import 'rpc_payload.dart';

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
/// This applies equally whether an entry is a bare capability or itself a
/// [vendCapabilityHandle] handle (e.g. one read out of another call's own
/// result via [requireCapabilityFromResult] and forwarded here) — the
/// runtime unwraps it to decide what to export, and disposes the handle you
/// handed it once that export is established (see
/// `_returnCapDescriptor`/`_resolveDescriptorForCapability` in
/// `two_party_connection.dart`). Reusing that same handle — or the bare
/// capability it wrapped — for anything *after* returning it here is a
/// use-after-ownership-transfer bug: if every reference to the underlying
/// capability happens to have been released by then, [vendCapabilityHandle]
/// catches the reuse itself rather than silently handing back a handle to
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

/// Describes a tail call: the entire result of the current dispatch should
/// be exactly the result of calling [target]'s [interfaceId]/[methodId]
/// method with [params]/[paramsCapabilities].
///
/// Returned by [Capability.tryTailCall]. When [target] is a capability
/// imported from the same peer connection that is asking for the current
/// dispatch, RPC-connected capabilities apply the Cap'n Proto Level 1 tail
/// call wire optimization (`Call.sendResultsTo=yourself` /
/// `Return.takeFromOtherQuestion`), avoiding an extra network round trip.
/// Otherwise this is a transparent pass-through with no special wire
/// behavior — semantically identical, just without the optimization.
class TailCall {
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

  /// Creates a tail call describing a dispatch to [target]'s
  /// [interfaceId]/[methodId] method with [params]/[paramsCapabilities].
  const TailCall(
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
class DispatchContext {
  /// A context that never reports cancellation — for dispatch paths that
  /// don't track it.
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
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => _DeferredCapCall(
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

/// Resolves the capability at pointer slot [ptrIndex], or throws an
/// [RpcException] that preserves why the pipeline target could not resolve.
///
/// Used for *local*, single-hop pipelining where [ptrIndex] is a
/// schema-known constant baked into generated code — `_DeferredCapCall`,
/// `_FutureCapCall`, `_ErrorCapCall`, and `_AsyncWireCapCall`'s
/// already-settled fallback in the RPC layer. Wire-level `receiverAnswer`/
/// `promisedAnswer` targets instead go through
/// [requireCapabilityFromResultPath], since those can name a capability
/// nested more than one struct deep in the result.
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
    final root = result.payload.getRootRaw();
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

/// Like [requireCapabilityFromResult], but resolves a capability reachable
/// via a chain of pointer-field hops (`path`) rather than a single
/// top-level index — used when a wire-level `receiverAnswer`/
/// `promisedAnswer` transform names a capability nested more than one
/// struct deep in the result (see rpc.capnp's `PromisedAnswer.Op`; each
/// entry but the last is followed as a nested struct pointer, the last as
/// the capability itself). Returns null instead of throwing on any
/// resolution failure.
Capability? capabilityFromResultPath(DispatchResult result, List<int> path) {
  try {
    return requireCapabilityFromResultPath(result, path);
  } catch (_) {
    return null;
  }
}

/// Throwing counterpart of [capabilityFromResultPath] — see
/// [requireCapabilityFromResult] for the single-hop version this
/// generalizes.
Capability requireCapabilityFromResultPath(
  DispatchResult result,
  List<int> path,
) {
  if (path.isEmpty) {
    throw const RpcException('transform path must not be empty');
  }
  if (result.caps.isEmpty) {
    throw const RpcException('result has no capability table entries');
  }
  try {
    var raw = result.payload.getRootRaw();
    for (var i = 0; i < path.length - 1; i++) {
      final idx = path[i];
      if (idx < 0 || idx >= raw.ptrWords) {
        throw RpcException(
          'pointer slot $idx in transform path is out of range',
        );
      }
      final next = raw.arena.resolveOptionalStructAt(
        raw.segment,
        raw.ptrWordOffset + idx,
        raw.nestingLimit,
      );
      if (next == null) {
        throw RpcException('pointer slot $idx in transform path is null');
      }
      raw = next;
    }
    final lastIdx = path.last;
    if (lastIdx < 0 || lastIdx >= raw.ptrWords) {
      throw RpcException('pointer slot $lastIdx is out of range');
    }
    final ptr = WirePointer.decode(
      raw.segment.data,
      raw.ptrWordOffset + lastIdx,
    );
    if (ptr is! CapabilityPointer) {
      throw RpcException(
        'pointer slot $lastIdx in result struct is not a capability',
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
// CapabilityTableBuilder: write-time capability accumulator.
//
// Generated `setXxxTyped(cap, capTable)` builder helpers (for a struct field
// whose type is an Interface or a List(Interface)) append to this instead of
// managing the outgoing capability table's indices by hand — a plain
// `List<Object?>` invites accidental corruption (clearing it, inserting a
// non-capability, reordering already-assigned entries) that would silently
// desync a builder's wire-level `CapabilityPointer.capabilityIndex` values
// from the accumulator's actual contents. One instance is shared by every
// `setXxxTyped` call reachable from a single generated client method's
// `build` callback (see the two-parameter `build` signature generated for a
// method whose params reach a capability through a nested struct/group/
// List(Interface) field), and its final `capabilities` is passed as that
// call's `paramsCapabilities`.
// ---------------------------------------------------------------------------

final class CapabilityTableBuilder {
  final List<Capability> _capabilities = [];

  /// Adds [capability] to the table and returns the wire-level cap-table
  /// index it was assigned — the value to write into the corresponding
  /// `CapabilityPointer` slot (e.g. via `setCapabilityField`).
  int add(Capability capability) {
    _capabilities.add(capability);
    return _capabilities.length - 1;
  }

  /// The accumulated capabilities in wire-table order, i.e. index `i` here
  /// is exactly what an earlier `add` call returning `i` referred to.
  ///
  /// A live, read-only *view* over the still-growing underlying list —
  /// deliberately not [List.unmodifiable] (a snapshot/copy): this getter is
  /// evaluated as part of a generated client method's `dispatchBuilding(...,
  /// paramsCapabilities: capTable.capabilities)` call, i.e. *before* the
  /// `build` callback that populates the table has run (Dart evaluates
  /// named-argument expressions left to right before the call itself, and
  /// `build` only runs inside `dispatchBuilding`'s body). A snapshot taken
  /// at that point would always be empty; `dispatchBuilding`'s contract is
  /// specifically that it only reads `paramsCapabilities` after `build`
  /// returns, so it needs the live reference.
  List<Capability> get capabilities => UnmodifiableListView(_capabilities);
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
///
/// Throws a [StateError] — unconditionally, in every build mode, not just
/// debug/test builds — if disposal for [target] has already been
/// *triggered* (its shared count already reached zero at least once — see
/// [_CapabilityHandle.dispose] — whether or not `target.dispose()` itself
/// has actually finished running yet). Vending a new handle at that point
/// would either resurrect an already-torn-down capability, or race a fresh
/// handle against a still in-flight disposal that could finish tearing
/// [target] down at any moment — neither is safe, so this is treated as a
/// caller bug rather than something to silently paper over with a second,
/// independent refcount cycle. This is a capability-lifecycle safety
/// invariant, not a debugging aid, so it's checked unconditionally — the
/// cost of one extra field comparison is negligible next to the object
/// allocation this function already does on every call.
///
/// This means a [Capability] meant to be exported repeatedly over a long
/// lifetime — e.g. [RpcSystem.serve]'s own `bootstrap`, handed to a fresh
/// [TwoPartyRpcConnection] for every accepted connection, potentially long
/// after an earlier one has come and gone — must never let this shared
/// count reach zero while the *owner* still considers it alive: `serve()`
/// itself holds its own vended handle for as long as the server is
/// running, specifically so no individual connection closing can ever
/// trigger `bootstrap`'s real disposal on its own.
Capability vendCapabilityHandle(Capability target) {
  final refCount = _capabilityRefCounts[target] ??= _CapabilityRefCount();
  if (refCount.disposeFuture != null) {
    throw StateError(
      'vendCapabilityHandle($target): disposal for this capability has '
      'already been triggered (every previously vended handle for it has '
      'been disposed) — vending a new handle now would either resurrect an '
      'already-torn-down capability or race a fresh handle against a still '
      'in-flight disposal. This usually means a reference to it was held '
      'onto and reused after ownership of it should have been considered '
      'transferred away (see DispatchResult\'s doc comment) — or, for a '
      'capability meant to be exported repeatedly over a long lifetime, that '
      'its owner should hold its own persistent vended handle for that whole '
      'lifetime instead of letting this shared count ever reach zero while '
      'still in use (see this function\'s own doc comment).',
    );
  }
  return _CapabilityHandle(target, refCount);
}

/// Unwraps any number of [vendCapabilityHandle] proxy layers around [cap],
/// returning the real underlying capability.
///
/// Callers that need to recognize what [cap] *actually is* — e.g. the RPC
/// connection layer deciding whether a params capability is an import from
/// the very peer it's being sent back to (and should therefore be encoded
/// as a cheap `receiverHosted` reference instead of a brand-new export) —
/// must unwrap it first: generated client stubs commonly vend a fresh
/// [_CapabilityHandle] every time their underlying capability is accessed
/// (e.g. a `.capability` getter backed by [requireCapabilityFromResult]),
/// so an `is _ImportedCapability`-style check against the un-unwrapped
/// value never matches, even though the same identity checks the wire
/// encoding relies on (e.g. `_exportIds[cap]`) still need every vended
/// handle for one underlying capability to resolve to that single shared
/// identity.
Capability unwrapVendedCapability(Capability cap) {
  var current = cap;
  while (current is _CapabilityHandle) {
    current = current._target;
  }
  return current;
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
    RpcPayload params, {
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
    RpcPayload params, {
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
    RpcPayload params, {
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
  TailCall? tryTailCall(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.tryTailCall(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  CapCall beginDispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.beginDispatch(
    interfaceId,
    methodId,
    params,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  Future<DispatchResult> dispatchBuilding(
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) build, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.dispatchBuilding(
    interfaceId,
    methodId,
    build,
    paramsCapabilities: paramsCapabilities,
  );

  @override
  Future<void> dispose() async {
    if (_handleDisposed) return;
    _handleDisposed = true;
    _refCount.count--;
    if (_refCount.count <= 0) {
      // Assigning disposeFuture here — synchronously, before this await
      // suspends — is itself what permanently marks this identity as
      // "disposal triggered" for vendCapabilityHandle's check, regardless
      // of whether target.dispose() ultimately succeeds or throws: a
      // failed disposal is still treated as terminal (matching
      // _disposeIgnoringErrors' "report, don't retry" handling elsewhere),
      // not as a reason to allow the identity to be vended fresh again.
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

  /// Like [pipelineResult], but for a capability reachable via a chain of
  /// pointer-field hops (each entry but the last followed as a nested
  /// struct pointer, the last as the capability itself) rather than a
  /// single top-level index — used by generated code when a result
  /// capability is nested inside one or more struct-typed fields instead of
  /// sitting directly on the result struct.
  ///
  /// [path] is never empty. Implementations that don't support multi-hop
  /// pipelining can implement this as:
  /// ```dart
  /// Capability pipelineResultPath(List<int> path) {
  ///   if (path.length == 1) return pipelineResult(path[0]);
  ///   throw UnsupportedError('multi-hop pipelining not supported');
  /// }
  /// ```
  /// (this is exactly what every `implements CapCall` class in this library
  /// does unless it can actually resolve deeper paths before [result]
  /// completes — see `_WirePipelinedCapability` in the RPC layer for the
  /// one that can). Note that — unlike an `abstract class` — `interface
  /// class` member bodies aren't inherited by `implements`, so every
  /// implementation, including this library's own, must define this method
  /// itself; there is no free default.
  Capability pipelineResultPath(List<int> path);
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
      // wraps resolves (see `_scheduleSenderPromiseResolve` in
      // `two_party_connection.dart`), which is released separately and
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
