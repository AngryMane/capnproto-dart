import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../capability/capability.dart'
    show Capability, DispatchCancellationController;

/// Holds the serialized result message and the corresponding cap table for a
/// completed incoming call. Both are needed by [TwoPartyRpcConnection] to
/// resolve promise-pipelined calls: the result bytes encode which pointer
/// slot maps to which cap table index via a `CapabilityPointer`, so the
/// lookup must parse the pointer rather than using the pointer-slot number
/// as a cap table index directly.
class ResolvedAnswer {
  final Uint8List resultBytes;
  final List<Capability> caps;
  ResolvedAnswer(this.resultBytes, this.caps);
}

/// Owns every incoming call a [TwoPartyRpcConnection] is currently (or has
/// recently) answered — resolved/pending/broken answer state for promise
/// pipelining, which result-capability export ids a Finish should release,
/// live dispatch cancellation controllers, and answers Finished by the peer
/// before their dispatch even completed.
///
/// Deliberately doesn't know how to actually send a Return/Finish, or how to
/// release an export — [finish] only ever hands back the result export ids
/// that need releasing; the caller (today, exclusively
/// `TwoPartyRpcConnection`) owns translating that into an actual
/// `ExportTable.release` call and any wire traffic. This class only owns the
/// invariant "each question id's answer bookkeeping reflects exactly one of:
/// not yet dispatched, dispatch pending, resolved-and-awaiting-Finish, or
/// fully settled" — see [isTracked], which callers rely on to detect a peer
/// illegally reusing a question id before that settling has happened.
class AnswerTable {
  final Map<int, List<int>> _answers = {};
  final Map<int, ResolvedAnswer> _answerCaps = {};
  final Map<int, Future<ResolvedAnswer>> _pendingCaps = {};
  final Map<int, CapnpException> _answerErrors = {};
  // Incoming questions that were finished by the peer before local dispatch
  // completed. Their dispatch result must be dropped instead of returned.
  final Set<int> _finishedAnswers = {};
  final Map<int, DispatchCancellationController> _dispatchCancellations = {};

  /// Number of incoming calls with some tracked answer-lifecycle state:
  /// dispatch in flight, a resolved-but-not-yet-finished answer, or a
  /// Finish that arrived before dispatch completed. Zero means every
  /// incoming call this connection has seen has fully settled.
  int get count =>
      <int>{
        ..._answers.keys,
        ..._answerCaps.keys,
        ..._answerErrors.keys,
        ..._pendingCaps.keys,
        ..._finishedAnswers,
      }.length;

  /// Number of incoming dispatches with a live [DispatchCancellationController]
  /// (i.e. dispatch is still running and could still observe cancellation).
  int get cancellationCount => _dispatchCancellations.length;

  /// Whether [qid] currently has any tracked answer-lifecycle state at all
  /// (dispatch in flight, a resolved-but-not-yet-finished answer, a
  /// dispatch that failed with an error still retained for a racing
  /// `takeFromOtherQuestion`, or a Finish that arrived before dispatch
  /// completed) — used to reject a peer illegally reusing a question id
  /// before it has fully settled. Mirrors [count]'s own definition of
  /// "tracked" exactly, so the two never disagree about whether a qid is
  /// still live.
  bool isTracked(int qid) =>
      _pendingCaps.containsKey(qid) ||
      _answerCaps.containsKey(qid) ||
      _answerErrors.containsKey(qid) ||
      _answers.containsKey(qid) ||
      _finishedAnswers.contains(qid);

  /// The resolved answer for [qid], if its dispatch has already completed
  /// successfully.
  ResolvedAnswer? resolvedFor(int qid) => _answerCaps[qid];

  /// The in-flight dispatch future for [qid], if it hasn't settled yet.
  Future<ResolvedAnswer>? pendingFor(int qid) => _pendingCaps[qid];

  /// The error [qid]'s dispatch failed with, if any — retained until Finish
  /// so a `takeFromOtherQuestion` racing with the failure still observes
  /// the original error rather than a misleading "unknown question id".
  CapnpException? errorFor(int qid) => _answerErrors[qid];

  /// Records [answer] as [qid]'s resolved result.
  void setResolved(int qid, ResolvedAnswer answer) => _answerCaps[qid] = answer;

  /// Drops [qid]'s resolved result, if any — without touching any other
  /// tracked state for it.
  void dropResolved(int qid) => _answerCaps.remove(qid);

  /// Records [error] as [qid]'s dispatch failure.
  void recordError(int qid, CapnpException error) => _answerErrors[qid] = error;

  /// Records [qid] as answered — [resultExportIds] are the export ids (if
  /// any) that a later Finish(releaseResultCaps: true) for it should
  /// release. An empty list is used whenever a Return was sent (or the
  /// equivalent resultsSentElsewhere/exception path) that carries no result
  /// capabilities of its own to release later.
  void recordAnswered(int qid, List<int> resultExportIds) =>
      _answers[qid] = resultExportIds;

  /// Registers [cancellation] as the live cancellation controller for
  /// [qid]'s in-flight dispatch.
  void trackCancellation(int qid, DispatchCancellationController cancellation) {
    _dispatchCancellations[qid] = cancellation;
  }

  /// Registers [pending] as the in-flight dispatch future for [qid], so a
  /// pipelined call arriving before it settles can queue behind it.
  void trackPending(int qid, Future<ResolvedAnswer> pending) {
    _pendingCaps[qid] = pending;
  }

  /// Drops dispatch-in-flight bookkeeping for [qid] — called unconditionally
  /// as the very first step of handling a dispatch's outcome (success or
  /// failure), before deciding what (if anything) to do next.
  void dispatchSettled(int qid) {
    _pendingCaps.remove(qid);
    _dispatchCancellations.remove(qid);
  }

  /// If the peer already sent Finish for [qid] while its dispatch was still
  /// running, drops every remaining trace of it (a Finished answer must
  /// never be resurrected) and returns `true`. A no-op returning `false`
  /// otherwise.
  bool consumeIfAlreadyFinished(int qid) {
    if (!_finishedAnswers.remove(qid)) return false;
    _answerCaps.remove(qid);
    _answerErrors.remove(qid);
    _answers.remove(qid);
    return true;
  }

  /// Applies an incoming Finish for [qid]: drops its resolved-answer state
  /// and returns the result export ids a `releaseResultCaps: true` Finish
  /// should release (the caller is responsible for actually releasing them
  /// — see [ExportTable.release] — this only ever returns what needs it).
  ///
  /// Returns `null` if [qid]'s dispatch was still pending when Finish
  /// arrived — in that case, this instead marks it as finished (so the
  /// eventual dispatch-settled handler drops its own bookkeeping instead of
  /// answering) and cancels its dispatch.
  List<int>? finish(int qid) {
    _answerCaps.remove(qid);
    _answerErrors.remove(qid);
    final resultExportIds = _answers.remove(qid);
    if (resultExportIds == null) {
      if (_pendingCaps.containsKey(qid)) {
        _finishedAnswers.add(qid);
        _dispatchCancellations.remove(qid)?.cancel();
      }
      return null;
    }
    _finishedAnswers.remove(qid);
    return resultExportIds;
  }

  /// Drops every tracked answer's state, canceling any still-live dispatch
  /// — called once when the owning connection tears down.
  void tearDown() {
    for (final cancellation in _dispatchCancellations.values) {
      cancellation.cancel();
    }
    _dispatchCancellations.clear();
    _answers.clear();
    _answerCaps.clear();
    _answerErrors.clear();
    _pendingCaps.clear();
    _finishedAnswers.clear();
  }
}
