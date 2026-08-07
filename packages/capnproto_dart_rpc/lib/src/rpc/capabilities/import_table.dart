import '../../capability/capability.dart' show Capability;
import '../rpc_exception.dart';

/// Tracks resolution/error state for a single remote capability this vat
/// imports — see [ImportTable].
class ImportState {
  final int importId;
  bool isPromise;
  bool receivedCall = false;
  Capability? replacement;
  Object? error;
  StackTrace? stackTrace;

  ImportState(this.importId, {this.isPromise = false});

  void resolveCapability(Capability cap) {
    if (error != null) return;
    replacement = cap;
  }

  void resolveError(Object err, [StackTrace? st]) {
    error = err;
    stackTrace = st;
  }
}

/// Owns every remote capability a [TwoPartyRpcConnection] currently imports
/// from its peer — import IDs (= the peer's own export IDs), this vat's own
/// local reference count for each, resolution/broken-promise state, and
/// batching outgoing Release counts.
///
/// Deliberately doesn't know how to actually send a Release or dispose a
/// capability — [releaseAndBatch]/[decrementRefcount] take a
/// `disposeIgnoringErrors` callback for the latter, and [takeBatchedReleases]
/// only ever hands back what needs sending, never sending anything itself;
/// the caller (today, `CapabilityProtocol`) owns both of those
/// wire-protocol concerns. This class only owns the invariant "an
/// import's refcount and tracking state stay consistent with how many
/// `_ImportedCapability` wrappers for it are still undisposed."
class ImportTable {
  final Map<int, int> _importRefCounts = {};
  final Map<int, ImportState> _imports = {};
  final Map<int, RpcException> _brokenImports = {};
  final Map<int, int> _pendingReleaseCounts = {};

  /// Number of remote capabilities currently imported from the peer (i.e.
  /// still holding at least one outstanding local reference).
  int get count => _imports.length;

  /// Number of imports recorded as broken (their promise resolved to an
  /// exception). Tracked separately from [count] because a broken import
  /// can still be observed after the import itself is released — this
  /// should settle back to zero once every import that ever broke has also
  /// been fully released.
  int get brokenCount => _brokenImports.length;

  /// Number of import IDs with a Release batched but not yet flushed to the
  /// wire (see [releaseAndBatch]/[takeBatchedReleases]). Always zero
  /// between microtasks — it's only ever non-zero for the duration of a
  /// batched flush that hasn't run yet.
  int get pendingReleaseCount => _pendingReleaseCounts.length;

  /// Whether [importId] currently has any tracked reference at all —
  /// distinguishes "we still care about this import" from "we've already
  /// fully released it, and a late message about it must not resurrect
  /// tracking state that nothing will ever clean up again" (see
  /// `CapabilityProtocol.handleResolve`'s matching doc comment).
  bool isTracked(int importId) => _importRefCounts.containsKey(importId);

  /// Retains a reference to [importId], creating its tracking state on
  /// first use. [isPromise] is set (and, once set, never unset by a later
  /// non-promise retain) if this particular retain is for a senderPromise
  /// descriptor rather than a plain senderHosted one.
  ImportState retain(int importId, {bool isPromise = false}) {
    _importRefCounts[importId] = (_importRefCounts[importId] ?? 0) + 1;
    final state = _imports.putIfAbsent(
      importId,
      () => ImportState(importId, isPromise: isPromise),
    );
    if (isPromise) state.isPromise = true;
    return state;
  }

  /// The tracking state for [importId], creating it (without retaining a
  /// reference — this alone does not affect the refcount) if it doesn't
  /// already exist. Used where the state object itself is needed (e.g. to
  /// resolve a pending promise) independent of whether this call should
  /// also hold a reference — callers that need to hold one use [retain]
  /// instead.
  ImportState getOrCreateState(int importId) =>
      _imports.putIfAbsent(importId, () => ImportState(importId));

  /// Records that [importId]'s promise resolved to an exception.
  void markBroken(int importId, RpcException error) {
    _brokenImports[importId] = error;
  }

  /// Throws the broken-promise error recorded for [importId] (see
  /// [markBroken]), if any — a no-op otherwise.
  void throwIfBroken(int importId) {
    final err = _brokenImports[importId];
    if (err != null) throw err;
  }

  /// Decrements [importId]'s local refcount and drops its tracking state
  /// once it reaches zero — without batching or sending a wire Release.
  /// Split out from [releaseAndBatch] so a caller that wants to apply the
  /// local effect immediately while folding the wire notification into
  /// something else entirely (`Return.releaseParamCaps`, rather than an
  /// explicit Release) can do so. A no-op if [importId] has no outstanding
  /// reference.
  ///
  /// Also disposes (via [disposeIgnoringErrors]) the dropped state's own
  /// `replacement`, if the promise this import tracks had resolved to one —
  /// every `_ImportedCapability` sharing this state forwards its calls to
  /// `replacement` instead of holding a separate reference of its own, so
  /// once every one of them has been released (this reaching zero),
  /// `replacement`'s own reference would otherwise never be released,
  /// permanently pinning whatever it wraps.
  void decrementRefcount(
    int importId,
    void Function(Capability) disposeIgnoringErrors,
  ) {
    final count = _importRefCounts[importId];
    if (count == null || count <= 0) return;
    if (count == 1) {
      _importRefCounts.remove(importId);
      _brokenImports.remove(importId);
      final replacement = _imports.remove(importId)?.replacement;
      if (replacement != null) {
        disposeIgnoringErrors(replacement);
      }
    } else {
      _importRefCounts[importId] = count - 1;
    }
  }

  /// [decrementRefcount]'s effect, plus batching a wire Release for
  /// [importId] — see [takeBatchedReleases]. Returns whether anything was
  /// actually released (`false` if [importId] has no outstanding
  /// reference, in which case nothing was batched either — the caller
  /// shouldn't bother scheduling a flush). Several releases issued without
  /// an intervening [takeBatchedReleases] coalesce into one batched count
  /// per import ID, rather than one entry each.
  bool releaseAndBatch(
    int importId,
    void Function(Capability) disposeIgnoringErrors,
  ) {
    final count = _importRefCounts[importId];
    if (count == null || count <= 0) return false;
    decrementRefcount(importId, disposeIgnoringErrors);
    _pendingReleaseCounts[importId] =
        (_pendingReleaseCounts[importId] ?? 0) + 1;
    return true;
  }

  /// Removes and returns every batched Release count accumulated since the
  /// last call (import ID → reference count to release) — the caller is
  /// responsible for actually sending one Release message per entry.
  Map<int, int> takeBatchedReleases() {
    if (_pendingReleaseCounts.isEmpty) return const {};
    final pending = Map<int, int>.of(_pendingReleaseCounts);
    _pendingReleaseCounts.clear();
    return pending;
  }

  /// Drops every import's tracking state — called once when the owning
  /// connection tears down. Deliberately doesn't touch any already-batched
  /// Release counts (see [takeBatchedReleases]): those still flush
  /// normally on their own schedule, and the connection's own `_sendRaw`
  /// silently no-ops once it's torn down, so there's nothing more this
  /// needs to do about them here.
  void tearDown() {
    _importRefCounts.clear();
    _imports.clear();
    _brokenImports.clear();
  }
}
