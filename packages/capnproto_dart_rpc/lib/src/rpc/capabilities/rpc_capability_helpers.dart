part of 'rpc_capability.dart';

/// Tracks parameter-capability disposal during one
/// `IncomingCallCoordinator._executeIncomingDispatch` call — see that
/// class's own
/// `_finishParameterCapabilityDisposalTrackingAndSendReleases`,
/// [startParameterCapabilityDisposalTracking], and
/// [finishParameterCapabilityDisposalTracking].
/// [wrappers] are every freshly-imported `_ImportedCapability` created for
/// this call's params (one per senderHosted/senderPromise capTable entry);
/// [disposedImportIds] accumulates the import ID each time one of them is
/// disposed while the window is open (see [_ImportedCapability]'s
/// `_deferredReleaseSink`) — as a `List`, not a `Set`, so a duplicate
/// import ID appearing more than once among the params (two distinct
/// wrapper objects for the same underlying capability) is still counted
/// once per wrapper, matching the refcount contribution each one made.
///
/// A plain data class, not a `Capability` — it exists only to be mutated by
/// [startParameterCapabilityDisposalTracking] and
/// [finishParameterCapabilityDisposalTracking] below, so it lives
/// here with its only callers rather than alongside the actual `Capability`
/// implementations in rpc_capability.dart.
class _ParameterCapabilityDisposalTracker {
  final List<_ImportedCapability> wrappers;
  final List<int> disposedImportIds = [];
  _ParameterCapabilityDisposalTracker(this.wrappers);
}

/// Builds the [Capability] proxying a remote capability whose import id
/// isn't known synchronously yet (the client-side bootstrap capability,
/// before the handshake resolves — see `TwoPartyRpcConnection.bootstrap`).
Capability createImportedCapability(
  RpcCapabilityDelegate delegate,
  Future<int> importIdFuture,
) => _ImportedCapability(delegate, importIdFuture);

/// As [createImportedCapability], for an import whose [ImportState] is
/// already known — see `CapabilityProtocol.acquireCapabilityFromDescriptor`'s
/// senderHosted/senderPromise branches, the only real caller.
Capability createImportedCapabilityFromState(
  RpcCapabilityDelegate delegate,
  ImportState state,
) => _ImportedCapability.fromState(delegate, state);

/// Builds the [Capability] a `receiverAnswer` capTable entry resolves to —
/// see `CapabilityProtocol.acquireCapabilityFromDescriptor`'s receiverAnswer
/// branch.
Capability createReceiverAnswerCapability(
  RpcCapabilityDelegate delegate,
  int questionId,
  List<int> path,
) => _ReceiverAnswerCapability(delegate, questionId, path);

/// Builds the [Capability] a `promisedAnswer`/pipelined call target
/// resolves to (see [_OutgoingQuestionDispatchHandle.pipelinedCapability]), bound to [delegate]
/// instead of a real connection. Test-only: nothing in production
/// constructs a `_PipelinedCapability` directly — it is always created
/// internally by `_OutgoingQuestionDispatchHandle`/
/// `_UnresolvedImportDispatchHandle` once a call is in
/// flight, so unlike the `create*` functions above it has no non-debug
/// counterpart.
@visibleForTesting
Capability debugCreatePipelinedCapability(
  RpcCapabilityDelegate delegate,
  int parentQid,
  List<int> transformPath,
  Future<DispatchResult> parentResult,
) => _PipelinedCapability(delegate, parentQid, transformPath, parentResult);

/// Tries to extract a reusable same-connection RPC reference from
/// [capability]. A resolved pipelined capability no longer has a valid
/// `receiverAnswer` reference, so it deliberately returns `null`.
RpcCapabilityReference? tryExtractRpcCapabilityReference(
  RpcCapabilityDelegate delegate,
  Capability capability,
) {
  if (capability is _ImportedCapability &&
      identical(capability._delegate, delegate)) {
    return ImportedCapabilityReference(
      capability._cachedState?.importId ?? capability._importIdFuture,
    );
  }
  if (capability is _PipelinedCapability &&
      identical(capability._delegate, delegate) &&
      !capability._hasResolved) {
    return PipelinedCapabilityReference(
      parentQuestionId: capability._parentQid,
      transformPath: capability._transformPath,
    );
  }
  return null;
}

/// Whether [capability] is a peer capability wrapper bound to [delegate].
/// Unlike reference extraction, a resolved pipelined wrapper remains bound
/// to the same peer connection and therefore still returns `true`.
bool isSameConnectionPeerCapability(
  RpcCapabilityDelegate delegate,
  Capability capability,
) {
  if (capability is _ImportedCapability) {
    return identical(capability._delegate, delegate);
  }
  if (capability is _PipelinedCapability) {
    return identical(capability._delegate, delegate);
  }
  return false;
}

/// Starts a deferred-release tracking window for whichever of
/// [paramsCapabilities] are same-connection `_ImportedCapability` wrappers
/// freshly imported for a call, bound to [delegate] — see
/// `IncomingCallCoordinator._executeIncomingDispatch`'s own doc comment for why.
/// [decrementImportReference] is called with an import id exactly once for
/// each wrapper disposed while the window is open. Returns an opaque
/// ticket (`null` if there's nothing to track) to pass back to
/// [finishParameterCapabilityDisposalTracking] once the call settles;
/// opaque because the
/// caller has no legitimate use for anything about it besides handing it
/// back unchanged.
Object? startParameterCapabilityDisposalTracking(
  RpcCapabilityDelegate delegate,
  List<Capability> paramsCapabilities,
  void Function(int importId) decrementImportReference,
) {
  final wrappers = paramsCapabilities
      .whereType<_ImportedCapability>()
      .where((c) => identical(c._delegate, delegate))
      .toList(growable: false);
  if (wrappers.isEmpty) return null;
  final tracker = _ParameterCapabilityDisposalTracker(wrappers);
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
/// [RpcCapabilityDelegate.releaseImport] path.
({bool allDisposed, List<int> explicitReleaseIds})
finishParameterCapabilityDisposalTracking(Object? ticket) {
  final tracker = ticket as _ParameterCapabilityDisposalTracker?;
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
