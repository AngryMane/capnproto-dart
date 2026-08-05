import 'dart:async';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../rpc_exception.dart';

/// Tracks a single pending embargo round-trip: this vat sent a
/// `senderLoopback` Disembargo and is waiting for the peer's matching
/// `receiverLoopback` reply before it's safe to let calls through the
/// capability the embargo covers (see [EmbargoTable.register]'s doc
/// comment for the full protocol rationale).
class _EmbargoEntry {
  final Completer<void> completer;
  Timer? timer;

  _EmbargoEntry(this.completer);
}

/// Owns every embargo round-trip a [TwoPartyRpcConnection] has in flight —
/// the Level 1 mechanism (see the Cap'n Proto RPC spec's "Level 1 embargoes"
/// section) that keeps a promise's calls correctly ordered relative to calls
/// made after it resolves to a capability this same vat already hosts.
///
/// Every embargo is registered with a fresh, monotonically increasing id
/// (ids are never reused, so entries never need identity checks against a
/// stale id being recycled — only against whether the *specific* entry a
/// timer or resolve() call was closed over is still the one currently
/// tracked). Callers looking to resolve/time out an embargo interact with it
/// purely through its id; the entry itself (and its `Completer`/`Timer`)
/// never needs to leave this file.
class EmbargoTable {
  final Map<int, _EmbargoEntry> _embargoes = {};
  int _nextEmbargoId = 0;

  /// Number of embargo round-trips currently awaiting the peer's
  /// receiverLoopback response.
  int get count => _embargoes.length;

  /// Registers a new embargo backed by [completer] (which the caller
  /// resolves to whatever capability the embargo was guarding, once this
  /// embargo itself settles), returning its id.
  ///
  /// If [timeout] is non-null, schedules [completer] to fail with an
  /// [RpcException] if the peer's receiverLoopback reply hasn't arrived
  /// (via [resolve]) by the time it elapses — without this bound, a peer
  /// that never replies would leave whatever's waiting on [completer]
  /// blocked forever. Passing `null` waits indefinitely.
  int register(Completer<void> completer, {Duration? timeout}) {
    final embargoId = _nextEmbargoId++;
    final entry = _EmbargoEntry(completer);
    _embargoes[embargoId] = entry;
    if (timeout != null) {
      entry.timer = Timer(timeout, () {
        // Already resolved by the peer's receiverLoopback reply (via
        // resolve()) or by tearDown() (which clears every embargo outright)
        // — nothing to do. Checked by identity, not just presence, so a
        // stale timer can never affect an entry other than the one it was
        // scheduled for — moot in practice since ids are never reused, but
        // cheap insurance against that assumption ever changing.
        if (_embargoes.remove(embargoId) != entry) return;
        if (!completer.isCompleted) {
          completer.completeError(
            RpcException(
              'Disembargo(id=$embargoId) timed out waiting for the peer\'s '
              'receiverLoopback reply after $timeout',
              kind: ErrorKind.overloaded,
            ),
          );
        }
      });
    }
    return embargoId;
  }

  /// Resolves the embargo for [embargoId] — the peer's receiverLoopback
  /// reply arrived — canceling its timeout (if any) and completing its
  /// completer, unless it's already completed. A no-op if [embargoId] isn't
  /// (or is no longer) tracked, e.g. its own timeout already fired.
  void resolve(int embargoId) {
    final embargo = _embargoes.remove(embargoId);
    if (embargo == null) return;
    embargo.timer?.cancel();
    if (!embargo.completer.isCompleted) {
      embargo.completer.complete();
    }
  }

  /// Fails every still-pending embargo with [err] and clears the table —
  /// called once when the owning connection tears down, so nothing is left
  /// waiting on a completer that will now never otherwise settle.
  void tearDown(Object err) {
    for (final embargo in _embargoes.values) {
      embargo.timer?.cancel();
      if (!embargo.completer.isCompleted) {
        embargo.completer.completeError(err);
      }
    }
    _embargoes.clear();
  }
}
