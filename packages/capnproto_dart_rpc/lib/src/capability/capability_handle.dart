part of 'capability.dart';

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
/// [CapabilityLease.dispose] — whether or not `target.dispose()` itself
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
CapabilityLease vendCapabilityHandle(Capability target) {
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
  return CapabilityLease._(target, refCount);
}

/// Unwraps any number of [vendCapabilityHandle] proxy layers around [cap],
/// returning the real underlying capability.
///
/// Callers that need to recognize what [cap] *actually is* — e.g. the RPC
/// connection layer deciding whether a params capability is an import from
/// the very peer it's being sent back to (and should therefore be encoded
/// as a cheap `receiverHosted` reference instead of a brand-new export) —
/// must unwrap it first: generated client stubs commonly vend a fresh
/// [CapabilityLease] every time their underlying capability is accessed
/// (e.g. a `.capability` getter backed by [requireCapabilityFromResult]),
/// so an `is _ImportedCapability`-style check against the un-unwrapped
/// value never matches, even though the same identity checks the wire
/// encoding relies on (e.g. `_exportIds[cap]`) still need every vended
/// handle for one underlying capability to resolve to that single shared
/// identity.
Capability unwrapVendedCapability(Capability cap) {
  var current = cap;
  while (current is CapabilityLease) {
    current = current._target;
  }
  return current;
}

/// A disposable, reference-counted proxy for another [Capability], returned
/// by [vendCapabilityHandle]. The name makes the disposal obligation
/// explicit: holding a [CapabilityLease] means you must call [dispose] on
/// it (not on the underlying capability directly) once you're done with it.
class CapabilityLease extends Capability {
  final Capability _target;
  final _CapabilityRefCount _refCount;
  bool _handleDisposed = false;

  CapabilityLease._(this._target, this._refCount) {
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
  DispatchHandle dispatchForPipelining(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => _target.dispatchForPipelining(
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
