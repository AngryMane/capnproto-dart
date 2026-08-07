import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../../capability/capability.dart'
    show Capability, DispatchCancellationController;

/// Holds the serialized result message and the corresponding cap table for a
/// completed incoming call. Both are needed by `IncomingCallCoordinator` to
/// resolve promise-pipelined calls: the result bytes encode which pointer
/// slot maps to which cap table index via a `CapabilityPointer`, so the
/// lookup must parse the pointer rather than using the pointer-slot number
/// as a cap table index directly.
class ResolvedAnswer {
  final Uint8List resultBytes;
  final List<Capability> caps;
  ResolvedAnswer(this.resultBytes, this.caps);
}

/// One incoming question's answer-lifecycle state, exactly one of which
/// applies at a time — see [AnswerTable]'s own doc comment for how
/// [TwoPartyRpcConnection] drives the transitions between them.
sealed class AnswerState {
  const AnswerState();
}

/// This question has an answer pending while its capability invocation is
/// still running. [pending] lets a pipelined call queue behind it;
/// [cancellation] lets a Finish that arrives before completion cancel the
/// invocation.
final class PendingAnswerState extends AnswerState {
  final Future<ResolvedAnswer> pending;
  final DispatchCancellationController cancellation;
  const PendingAnswerState(this.pending, this.cancellation);
}

/// A Return was already sent (or the equivalent resultsSentElsewhere path
/// taken) for this question, and it's now awaiting Finish. [resolved] is
/// only set when pipelined calls can target this answer's result — `null`
/// for a Return variant with no result payload of its own (an exception, or
/// a takeFromOtherQuestion forward). [resultExportIds] are the export ids
/// (if any) that a later Finish(releaseResultCaps: true) should release.
final class AnsweredState extends AnswerState {
  final ResolvedAnswer? resolved;
  final List<int> resultExportIds;
  const AnsweredState({this.resolved, this.resultExportIds = const []});
}

/// This question's dispatch failed, and the error is retained (instead of
/// just being sent as a Return.exception and forgotten) so a
/// `takeFromOtherQuestion` racing with the failure still observes the
/// original error rather than a misleading "unknown question id" — only
/// reachable via the sendResultsTo=yourself path, where nothing is put on
/// the wire that a normal Return.exception would otherwise carry.
final class FailedAnswerState extends AnswerState {
  final CapnpException error;
  const FailedAnswerState(this.error);
}

/// The peer already sent Finish for this question while its dispatch was
/// still running. The eventual dispatch result must be dropped instead of
/// resurrecting answer state for it.
final class FinishedBeforeCompletionState extends AnswerState {
  const FinishedBeforeCompletionState();
}

/// Owns every incoming call a `TwoPartyRpcConnection` is currently (or has
/// recently) answered, as one [AnswerState] entry per question id —
/// resolved/pending/broken answer state for promise pipelining, which
/// result-capability export ids a Finish should release, live dispatch
/// cancellation controllers, and answers Finished by the peer before their
/// dispatch even completed all live as fields of whichever single state a
/// question id is currently in, so invalid combinations (e.g. a retained
/// error alongside a live dispatch) can't be constructed through this
/// table's API.
///
/// Deliberately doesn't know how to actually send a Return/Finish, or how to
/// release an export — [recordPeerFinish] only ever hands back the result
/// export ids
/// that need releasing; the caller (today, `IncomingCallCoordinator`) owns
/// translating that into an actual `ExportTable.release` call and any wire
/// traffic.
class AnswerTable {
  final Map<int, AnswerState> _answers = {};

  /// Number of incoming calls with some tracked answer-lifecycle state:
  /// dispatch in flight, a resolved-but-not-yet-finished answer, or a
  /// Finish that arrived before dispatch completed. Zero means every
  /// incoming call this connection has seen has fully settled.
  int get count => _answers.length;

  /// Number of incoming dispatches with a live [DispatchCancellationController]
  /// (i.e. dispatch is still running and could still observe cancellation).
  int get cancellationCount =>
      _answers.values.whereType<PendingAnswerState>().length;

  /// Whether [qid] currently has any tracked answer-lifecycle state at all
  /// — used to reject a peer illegally reusing a question id before it has
  /// fully settled.
  bool isTracked(int qid) => _answers.containsKey(qid);

  /// The resolved answer for [qid], if it has one available for promise
  /// pipelining right now (a completed dispatch, or a directly-resolved
  /// answer such as Bootstrap's).
  ResolvedAnswer? resolvedFor(int qid) {
    final state = _answers[qid];
    return state is AnsweredState ? state.resolved : null;
  }

  /// The in-flight dispatch future for [qid], if it hasn't settled yet.
  Future<ResolvedAnswer>? pendingFor(int qid) {
    final state = _answers[qid];
    return state is PendingAnswerState ? state.pending : null;
  }

  /// The error [qid]'s dispatch failed with, if any — retained until Finish
  /// so a `takeFromOtherQuestion` racing with the failure still observes
  /// the original error rather than a misleading "unknown question id".
  CapnpException? errorFor(int qid) {
    final state = _answers[qid];
    return state is FailedAnswerState ? state.error : null;
  }

  /// Records [qid] as pending: [pending] lets a pipelined call queue behind
  /// the running capability invocation, and [cancellation] lets an early
  /// Finish cancel it.
  void recordPendingAnswer(
    int qid,
    Future<ResolvedAnswer> pending,
    DispatchCancellationController cancellation,
  ) {
    _answers[qid] = PendingAnswerState(pending, cancellation);
  }

  /// Clears [qid]'s pending-answer lifecycle after its capability invocation
  /// settles on a path that records no further answer state (connection torn
  /// down, or a plain exception Return that needs no Finish), and reports
  /// whether the peer already sent Finish while it was pending. When `true`,
  /// every trace of [qid] has already been dropped (a Finished answer must
  /// never be resurrected) and the caller must discard the dispatch's
  /// result instead of answering it.
  ///
  /// A path that *does* go on to record an answer must use
  /// [tryRecordAnswer]/[tryRecordFailedAnswer] instead —
  /// calling this first would still detect the early Finish correctly, but
  /// leaves [qid] briefly untracked in between, which a caller that then
  /// sends the Return before its own follow-up call can observe (see those
  /// methods' doc comments).
  bool clearPendingAnswer(int qid) {
    final wasFinishedEarly = _answers[qid] is FinishedBeforeCompletionState;
    _answers.remove(qid);
    return wasFinishedEarly;
  }

  /// Atomically records [qid] as answered after its capability invocation
  /// succeeds. If Finish already arrived while the answer was pending, drops
  /// every trace of it and returns `false` — the caller must then discard
  /// the dispatch's result instead of answering it, exactly like
  /// [clearPendingAnswer] reporting `true`. Otherwise records
  /// [resolved]/[resultExportIds] as the answer awaiting Finish (see
  /// [recordAnswer], which this shares its recorded state with)
  /// and returns `true`.
  ///
  /// Call this *before* actually sending the Return. Unlike calling
  /// [clearPendingAnswer] first and a separate call to record the answer
  /// second, this never leaves [qid] briefly untracked in between — a
  /// caller that sent the Return between those two calls would otherwise
  /// risk a synchronously-delivered Finish, duplicate Call, or pipelined
  /// Call for the same [qid] (e.g. over an in-memory or `sync: true`
  /// transport, where sending can reenter this table before the second
  /// call ever runs) observing state this table never actually held.
  bool tryRecordAnswer(
    int qid, {
    ResolvedAnswer? resolved,
    List<int> resultExportIds = const [],
  }) {
    if (_answers[qid] is FinishedBeforeCompletionState) {
      _answers.remove(qid);
      return false;
    }
    _answers[qid] = AnsweredState(
      resolved: resolved,
      resultExportIds: resultExportIds,
    );
    return true;
  }

  /// Atomically records [qid] as failed after its capability invocation, with
  /// [error] retained for a racing `takeFromOtherQuestion` —
  /// only used on the sendResultsTo=yourself failure path, where nothing
  /// is put on the wire that a normal Return.exception would otherwise
  /// carry. Same atomicity contract: call before sending, `false` means
  /// discard the failure instead of answering it.
  bool tryRecordFailedAnswer(int qid, CapnpException error) {
    if (_answers[qid] is FinishedBeforeCompletionState) {
      _answers.remove(qid);
      return false;
    }
    _answers[qid] = FailedAnswerState(error);
    return true;
  }

  /// Records [qid] as answered and awaiting Finish, for a Return sent
  /// without ever going through a live dispatch (so no early-Finish race
  /// is possible — see [tryRecordAnswer] for the dispatch
  /// counterpart that must guard against one): a directly-resolved answer
  /// such as Bootstrap's ([resolved] set, no export ids of its own to
  /// release), or a Return with no result payload at all (an exception, or
  /// a takeFromOtherQuestion forward — neither [resolved] nor
  /// [resultExportIds] set).
  void recordAnswer(
    int qid, {
    ResolvedAnswer? resolved,
    List<int> resultExportIds = const [],
  }) {
    _answers[qid] = AnsweredState(
      resolved: resolved,
      resultExportIds: resultExportIds,
    );
  }

  /// Clears the completed answer bookkeeping for a Return sent with
  /// `noFinishNeeded: true`.
  ///
  /// Only an [AnsweredState] with no result capabilities is valid here. A
  /// missing entry is also a no-op because synchronously sending the Return
  /// can reenter [recordPeerFinish], which may consume the state first.
  /// This never cancels a dispatch or releases an export.
  void clearAnswerForNoFinishNeeded(int qid) {
    final state = _answers[qid];
    if (state == null) return;
    if (state case AnsweredState(:final resolved, :final resultExportIds)) {
      if (resultExportIds.isNotEmpty || (resolved?.caps.isNotEmpty ?? false)) {
        throw StateError(
          'answer $qid has result capabilities and needs peer Finish',
        );
      }
      _answers.remove(qid);
      return;
    }
    throw StateError(
      'answer $qid is ${state.runtimeType}, not a completed answer',
    );
  }

  /// Applies an incoming Finish for [qid]: drops its answer state and
  /// returns the result export ids a `releaseResultCaps: true` Finish
  /// should release (the caller is responsible for actually releasing them
  /// — see [ExportTable.release] — this only ever returns what needs it).
  ///
  /// Returns `null` if [qid]'s dispatch was still pending when Finish
  /// arrived — in that case, this instead marks it as finished (so the
  /// eventual dispatch-settled handler drops its own bookkeeping instead of
  /// answering) and cancels its dispatch. Also returns `null` (as a no-op)
  /// if [qid] is unknown, or already marked finished by an earlier call —
  /// a Finish must never resurrect or double-cancel anything.
  ///
  /// TODO(#109): Do not cancel while an already-received pipelined call
  /// still depends on this answer.
  List<int>? recordPeerFinish(int qid) {
    final state = _answers[qid];
    switch (state) {
      case null:
      case FinishedBeforeCompletionState():
        return null;
      case PendingAnswerState(:final cancellation):
        _answers[qid] = const FinishedBeforeCompletionState();
        cancellation.cancel();
        return null;
      case AnsweredState(:final resultExportIds):
        _answers.remove(qid);
        return resultExportIds;
      case FailedAnswerState():
        _answers.remove(qid);
        return const [];
    }
  }

  /// Drops every tracked answer's state, canceling any still-live dispatch
  /// — called once when the owning connection tears down.
  void tearDown() {
    for (final state in _answers.values) {
      if (state is PendingAnswerState) state.cancellation.cancel();
    }
    _answers.clear();
  }
}
