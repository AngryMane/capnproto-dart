import 'dart:collection';

import '../capability/capability.dart'
    show Capability, CapabilityLease, vendCapabilityHandle;

/// Tracks a single locally-exported capability and the peer's remote
/// reference count for it — see [ExportTable].
class _ExportEntry {
  /// The real, unwrapped capability this export refers to — used as the
  /// [ExportTable]'s own dedup key and for dispatching incoming calls.
  /// Never disposed directly; see [ownedReference].
  final Capability identity;

  /// A [vendCapabilityHandle] reference this export table owns for
  /// [identity], sharing the same refcount as any other handle another
  /// piece of code may still hold for it — e.g. when [identity] was
  /// obtained from a different connection (or from this same connection's
  /// own result-reading helpers) and relayed here while the code that
  /// vended it is still holding its own handle. Disposing *this* reference
  /// (instead of [identity] itself) once the peer's references reach zero
  /// ensures [identity] is only really torn down once every other
  /// outstanding reference to it is gone too — see vendCapabilityHandle's
  /// doc comment for the shared-refcount mechanism this participates in.
  final CapabilityLease ownedReference;

  // How many times the peer holds a reference to this export.
  // Incremented on every export (or re-export); decremented on Release.
  int remoteRefCount;

  _ExportEntry(this.identity)
    : ownedReference = vendCapabilityHandle(identity),
      remoteRefCount = 1;
}

/// Owns every capability a [TwoPartyRpcConnection] has exported to its
/// peer — export IDs, the peer's outstanding reference count for each, and
/// (via `dispose` callbacks passed in by the caller) tearing an export's own
/// reference down once the peer's count reaches zero.
///
/// Deliberately doesn't know about `RpcException`, `_sendRaw`, or any other
/// wire-protocol concern — callers (today, exclusively `TwoPartyRpcConnection`)
/// own translating this table's state into/out of actual messages; this
/// class only owns the invariant "an export's `ownedReference` is disposed
/// exactly once, exactly when the peer's remote refcount for it reaches
/// zero."
class ExportTable {
  final Map<int, _ExportEntry> _exports = {};
  // Reverse map: capability identity → its export ID (for dedup on
  // re-export).
  final Map<Capability, int> _exportIds = HashMap<Capability, int>.identity();
  // Bootstrap is registered at export ID 0 (see [registerBootstrap]);
  // ordinary exports start at 1.
  int _nextExportId = 1;
  // Sender-promise export IDs (see TwoPartyRpcConnection's
  // `_scheduleSenderPromiseResolve`) currently scheduled to notify the peer
  // once they resolve — tracked here (rather than as a plain field on the
  // connection) since every mutation happens alongside an `_exports`/
  // `_exportIds` change (a promise being superseded, released, or torn
  // down invalidates its scheduled resolution too).
  final Set<int> _senderPromiseResolves = {};

  /// Number of capabilities currently exported to the peer (i.e. still
  /// holding at least one outstanding remote reference).
  int get count => _exports.length;

  /// Registers [identity] as export 0 (bootstrap) — see
  /// `TwoPartyRpcConnection.server`'s own doc comment for the ownership
  /// contract this establishes. Its remote refcount starts at 0, not 1
  /// (unlike [getOrCreate]'s default for ordinary export vends): the entry
  /// needs to exist immediately so incoming Call/Bootstrap messages can
  /// route to it, but the peer doesn't actually hold a reference until it
  /// sends its own Bootstrap request — see [retainExisting], which
  /// increments this on every one answered.
  void registerBootstrap(Capability identity) {
    _exports[0] = _ExportEntry(identity)..remoteRefCount = 0;
    _exportIds[identity] = 0;
  }

  /// Increments the remote refcount for the export already registered at
  /// [exportId] and returns its identity — or `null` if nothing is
  /// currently exported there. Unlike [getOrCreate], never creates a new
  /// export; used for a fresh Bootstrap request handing the peer another
  /// reference to the same export-0 capability (see [registerBootstrap]'s
  /// doc comment).
  Capability? retainExisting(int exportId) {
    final entry = _exports[exportId];
    if (entry == null) return null;
    entry.remoteRefCount++;
    return entry.identity;
  }

  /// The identity exported at [exportId], or `null` if nothing is exported
  /// there.
  Capability? identityFor(int exportId) => _exports[exportId]?.identity;

  /// The remote refcount currently outstanding for [exportId], or `null` if
  /// nothing is exported there — used to validate an incoming `Release`
  /// before applying it (see [releaseRef]'s doc comment: a peer legitimately
  /// releasing more references than it holds is a protocol violation the
  /// caller needs the actual count to report).
  int? remoteRefCountFor(int exportId) => _exports[exportId]?.remoteRefCount;

  /// Whether [exportId] is still exported and is (by identity) [expected] —
  /// i.e. nothing has released or superseded it since it was last scheduled
  /// for sender-promise resolution.
  bool isCurrentIdentity(int exportId, Capability expected) {
    final entry = _exports[exportId];
    return entry != null && identical(entry.identity, expected);
  }

  /// Returns the existing export ID for [identity] (incrementing its remote
  /// ref count), or allocates a new export ID — with its own
  /// [vendCapabilityHandle] [_ExportEntry.ownedReference] — if this is the
  /// first export. [identity] must already be unwrapped (see
  /// `unwrapVendedCapability`): every caller of this method unwraps first,
  /// so that two different vended handles for the same underlying
  /// capability dedupe to the same export instead of each creating their
  /// own.
  int getOrCreate(Capability identity) {
    final existing = _exportIds[identity];
    if (existing != null) {
      _exports[existing]!.remoteRefCount++;
      return existing;
    }
    final eid = _nextExportId++;
    _exports[eid] = _ExportEntry(identity);
    _exportIds[identity] = eid;
    return eid;
  }

  /// Marks [promiseId] as scheduled for sender-promise resolution,
  /// returning whether it wasn't already (matching `Set.add`'s own return
  /// convention) — a caller that gets `false` back must not schedule a
  /// second, redundant resolution watcher for the same promise.
  bool markScheduled(int promiseId) => _senderPromiseResolves.add(promiseId);

  /// Clears [promiseId]'s scheduled-resolution marker, once its resolution
  /// watcher actually completes (successfully or not) — allowing a later
  /// re-export of the same promise (if it's still exported under a
  /// different id, or re-exported after being released and re-created) to
  /// be scheduled again.
  void clearScheduled(int promiseId) => _senderPromiseResolves.remove(promiseId);

  /// Core effect of releasing [referenceCount] references to [exportId]:
  /// decrements its remote refcount and, once it reaches zero, drops the
  /// export and disposes this export's own reference to the underlying
  /// capability via [disposeIgnoringErrors] (see [_ExportEntry.ownedReference]
  /// — this only tears the capability down for real once every other
  /// outstanding `vendCapabilityHandle` reference to it, held anywhere
  /// else, has also been disposed). A no-op if [exportId] isn't currently
  /// exported.
  ///
  /// Used both for a real incoming `Release` (after the caller's own
  /// protocol-violation checks against [remoteRefCountFor] — no such check
  /// is done here) and for applying `Return.releaseParamCaps` locally (the
  /// count released there is exactly what this vat itself put in the
  /// matching Call's own capTable, so it's trusted without re-validation).
  void releaseRef(
    int exportId,
    int referenceCount,
    void Function(Capability) disposeIgnoringErrors,
  ) {
    final entry = _exports[exportId];
    if (entry == null) return;
    entry.remoteRefCount -= referenceCount;
    if (entry.remoteRefCount <= 0) {
      _exports.remove(exportId);
      _exportIds.remove(entry.identity);
      _senderPromiseResolves.remove(exportId);
      disposeIgnoringErrors(entry.ownedReference);
    }
  }

  /// Unconditionally releases exactly one reference to [exportId] — see
  /// [releaseRef]'s matching doc comment. Used when this vat itself decides
  /// an export is no longer needed (e.g. `Finish(releaseResultCaps: true)`
  /// on the answer that exported it), as opposed to an explicit release
  /// count from the peer.
  void release(int exportId, void Function(Capability) disposeIgnoringErrors) {
    releaseRef(exportId, 1, disposeIgnoringErrors);
  }

  /// Disposes every export's own reference to its underlying capability and
  /// clears the table — called once when the owning connection tears down.
  void tearDown(void Function(Capability) disposeIgnoringErrors) {
    for (final entry in _exports.values) {
      disposeIgnoringErrors(entry.ownedReference);
    }
    _exports.clear();
    _exportIds.clear();
    _senderPromiseResolves.clear();
  }
}
