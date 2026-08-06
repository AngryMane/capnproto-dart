part of 'rpc_capability.dart';

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
///
/// A plain data class, not a `Capability` — it exists only to be mutated by
/// [beginParamCapsRelease]/[finalizeParamCapsRelease] below, so it lives
/// here with its only callers rather than alongside the actual `Capability`
/// implementations in rpc_capability.dart.
class _ParamCapsReleaseTracker {
  final List<_ImportedCapability> wrappers;
  final List<int> disposedImportIds = [];
  _ParamCapsReleaseTracker(this.wrappers);
}

/// Builds the [Capability] proxying a remote capability whose import id
/// isn't known synchronously yet (the client-side bootstrap capability,
/// before the handshake resolves — see `TwoPartyRpcConnection.bootstrap`).
Capability createImportedCapability(
  WireCapabilityContext context,
  Future<int> importIdFuture,
) => _ImportedCapability(context, importIdFuture);

/// As [createImportedCapability], for an import whose [ImportState] is
/// already known — see `CapabilityProtocol.capabilityFromDescriptor`'s
/// senderHosted/senderPromise branches, the only real caller.
Capability createImportedCapabilityFromState(
  WireCapabilityContext context,
  ImportState state,
) => _ImportedCapability.fromState(context, state);

/// Builds the [Capability] a `receiverAnswer` capTable entry resolves to —
/// see `CapabilityProtocol.capabilityFromDescriptor`'s receiverAnswer
/// branch.
Capability createReceiverAnswerCapability(
  WireCapabilityContext context,
  int questionId,
  List<int> path,
) => _ReceiverAnswerCapability(context, questionId, path);

/// Builds the [Capability] a `promisedAnswer`/pipelined call target
/// resolves to (see [_OutgoingQuestionCapCall.pipelineResult]), bound to [context]
/// instead of a real connection. Test-only: nothing in production
/// constructs a `_PipelinedCapability` directly — it's always vended
/// internally by `_OutgoingQuestionCapCall`/`_UnresolvedImportCapCall` once a call is in
/// flight, so unlike the `create*` functions above it has no non-debug
/// counterpart.
@visibleForTesting
Capability debugCreatePipelinedCapability(
  WireCapabilityContext context,
  int parentQid,
  List<int> transformPath,
  Future<DispatchResult> parentResult,
) => _PipelinedCapability(context, parentQid, transformPath, parentResult);

/// Classifies [capability] as wire-hosted or not, from [context]'s own
/// point of view — see [WireCapabilityKind]'s doc comment.
/// `_PipelinedCapability` is never constructed outside this library
/// (only `_OutgoingQuestionCapCall`/`_UnresolvedImportCapCall` do), so unlike
/// [createImportedCapability]/[createReceiverAnswerCapability] it has no
/// matching `create*` function here.
WireCapabilityKind classifyWireCapability(
  WireCapabilityContext context,
  Capability capability,
) {
  if (capability is _ImportedCapability &&
      identical(capability._conn, context)) {
    return ImportedWireCapability(
      capability._cachedState?.importId ?? capability._importIdFuture,
    );
  }
  if (capability is _PipelinedCapability &&
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
/// [paramsCapabilities] are same-connection `_ImportedCapability` wrappers
/// freshly imported for a call, bound to [context] — see
/// `IncomingCallCoordinator._runDispatch`'s own doc comment for why.
/// [decrementImportReference] is called with an import id exactly once for
/// each wrapper disposed while the window is open. Returns an opaque
/// ticket (`null` if there's nothing to track) to pass back to
/// [finalizeParamCapsRelease] once the call settles; opaque because the
/// caller has no legitimate use for anything about it besides handing it
/// back unchanged.
Object? beginParamCapsRelease(
  WireCapabilityContext context,
  List<Capability> paramsCapabilities,
  void Function(int importId) decrementImportReference,
) {
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
