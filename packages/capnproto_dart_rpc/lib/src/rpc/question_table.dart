import 'dart:async';

import 'rpc_proto.dart';

/// Owns every outgoing question a [TwoPartyRpcConnection] currently has in
/// flight — allocation of fresh question ids, each one's `Return` completer
/// and "reached the wire yet" completer, and which senderHosted/senderPromise
/// export ids its own params capabilities produced (so `Return.
/// releaseParamCaps` can be applied, or a failed send's export refs rolled
/// back, once that's known).
///
/// Deliberately doesn't know how to actually build/send a Call, apply
/// `Return.releaseParamCaps` against the [ExportTable], or interpret a
/// `Return` message — the caller (today, exclusively `TwoPartyRpcConnection`)
/// owns all of that; this class only owns the invariant "a question id's
/// tracking state exists from the moment it's allocated until its `Return`
/// (or connection teardown) removes it."
///
/// Deliberately excludes the bootstrap-capability fields
/// (`_bootstrapCap`/`_bootstrapCompleter`/`_bootstrapQuestionId`): those
/// still live on `TwoPartyRpcConnection` itself, since `_bootstrapCap` is
/// typed `_ImportedCapability?`, a class that isn't visible outside
/// `two_party_connection.dart`.
class QuestionTable {
  final Map<int, Completer<RpcMessage>> _questions = {};
  final Map<int, Completer<void>> _questionSent = {};
  int _nextQuestionId = 0;
  final Map<int, List<int>> _questionParamExportIds = {};

  /// Number of outgoing questions still awaiting their `Return`.
  int get pendingCount => _questions.length;

  /// Number of outgoing questions whose Call hasn't reached the wire yet.
  int get pendingSentCount => _questionSent.length;

  /// Allocates a fresh question id and registers a `Return` completer for
  /// it, without any matching sent-tracking — used only by `bootstrap()`,
  /// whose Bootstrap message is built and sent synchronously in the same
  /// breath (nothing ever pipelines off of it, so there's no "has this
  /// reached the wire yet" question to answer).
  int allocateForBootstrap() {
    final qid = _nextQuestionId++;
    _questions[qid] = Completer<RpcMessage>();
    return qid;
  }

  /// Allocates a fresh question id plus its matching `Return` completer and
  /// sent completer — used by every real outgoing Call (`_startCall`,
  /// `_startResolvedImportCall`, `_startCallBuilding`,
  /// `_sendTailForwardCall`).
  (int, Completer<RpcMessage>, Completer<void>) allocate() {
    final qid = _nextQuestionId++;
    final completer = Completer<RpcMessage>();
    _questions[qid] = completer;
    final sentCompleter = Completer<void>();
    _questionSent[qid] = sentCompleter;
    return (qid, completer, sentCompleter);
  }

  /// The sent completer for [qid], if its Call hasn't reached the wire yet
  /// — used to make a promisedAnswer-target Call, or a receiverAnswer param
  /// capability referencing [qid], wait for it to be sent first.
  Completer<void>? sentCompleterFor(int qid) => _questionSent[qid];

  /// Marks [qid]'s Call as sent: completes its sent completer (if not
  /// already) and drops sent-tracking for it — nothing waits on it again
  /// past this point.
  void markSent(int qid) {
    final sentCompleter = _questionSent.remove(qid);
    if (sentCompleter != null && !sentCompleter.isCompleted) {
      sentCompleter.complete();
    }
  }

  /// Drops [qid]'s tracking entirely — its Call failed to build/send, so
  /// there is no `Return` to ever await and nothing further to wait to be
  /// sent. Callers still complete the `completer`/`sentCompleter` they got
  /// from [allocate] with the failure themselves.
  void abandon(int qid) {
    _questions.remove(qid);
    _questionSent.remove(qid);
  }

  /// Records the senderHosted/senderPromise export ids among an outgoing
  /// Call's own capTable (this vat's params capabilities) against [qid], so
  /// a later `Return.releaseParamCaps` can be applied locally once it's
  /// known, or rolled back if the Call never reached the wire. A no-op for
  /// an empty [ids] — nothing to release either way.
  void recordParamExportIds(int qid, List<int> ids) {
    if (ids.isNotEmpty) _questionParamExportIds[qid] = ids;
  }

  /// Removes and returns [qid]'s recorded params export ids, if any —
  /// called at most once per question, either to roll them back (the Call
  /// never reached the wire) or to apply `Return.releaseParamCaps` (it did,
  /// and a `Return` arrived).
  List<int>? takeParamExportIds(int qid) => _questionParamExportIds.remove(qid);

  /// Removes and returns [qid]'s `Return` completer, if it's still tracked
  /// — `null` if [qid] is unknown (a stray/duplicate `Return`, or one for a
  /// question already torn down).
  Completer<RpcMessage>? takeReturn(int qid) => _questions.remove(qid);

  /// Fails every still-pending question (both awaiting-Return and
  /// awaiting-sent) with [err] and clears all tracking — called once when
  /// the owning connection tears down.
  void tearDown(Object err) {
    for (final c in _questions.values) {
      if (!c.isCompleted) {
        c.future.ignore();
        c.completeError(err);
      }
    }
    _questions.clear();
    for (final c in _questionSent.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _questionSent.clear();
  }
}
