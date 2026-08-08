import 'dart:async';
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

/// Tracks pipelined calls currently depending on one [PendingAnswerState]'s
/// eventual result, and the peer's early-Finish state for it. Created once
/// per [PendingAnswerState] and lives independently of whatever this table
/// does with the owning question id afterward: once this vat sends its own
/// Return for that qid, the qid's own protocol lifecycle is over and the
/// peer may legally reuse it for an unrelated new Call, but a
/// still-outstanding pipelined dependent (registered via
/// [AnswerTable.tryBeginPipelinedDependency], holding a
/// [_PipelineDependencyTicket] onto this object as its opaque ticket) must
/// still eventually finalize export release against the *original* answer,
/// never whatever new [AnswerState] now lives under a reused qid — see
/// [AnswerTable.endPipelinedDependency].
///
/// Result-export release depends on two independent conditions that don't
/// have a guaranteed relative order: every dependent draining
/// ([dependentCount] reaching 0) and the parent dispatch's own settle-time
/// bookkeeping recording [resultExportIds]. [tryTakeResultExports] is the
/// rendezvous both sides call into; whichever satisfies the last condition
/// is the one that actually gets a non-null result back.
final class _PipelineDependencyTracker {
  /// Pipelined calls that queued behind the still-running dispatch and
  /// haven't yet finished with its eventual result.
  int dependentCount = 0;

  /// Whether the peer already sent Finish for the owning question while
  /// this tracker's dependents (if any) were still outstanding.
  bool peerFinished = false;

  /// The `releaseResultCaps` flag from that Finish — only meaningful once
  /// [peerFinished] is set.
  bool releaseResultCapsOnFinish = true;

  /// The owning answer's result export ids, once its settle-time
  /// bookkeeping has run. `null` means "not determined yet", distinct from
  /// "determined, and empty" (`const []`).
  List<int>? resultExportIds;

  bool _resultReleaseTaken = false;

  /// Returns the export ids to release now that every dependent has
  /// drained, [resultExportIds] is known, [releaseResultCapsOnFinish] was
  /// requested, and nobody has already taken them — `null` otherwise.
  /// Safe to call from either side of the rendezvous (a draining
  /// dependent, or the parent's own settle-time bookkeeping) in any order;
  /// returns non-null at most once, no matter which side happens to
  /// satisfy the last condition.
  List<int>? tryTakeResultExports() {
    if (!peerFinished) return null;
    if (dependentCount != 0) return null;
    final ids = resultExportIds;
    if (ids == null) return null;
    if (!releaseResultCapsOnFinish) return null;
    if (_resultReleaseTaken) return null;
    _resultReleaseTaken = true;
    return ids;
  }
}

/// One-shot handle for a single pipelined call's dependency on a
/// [_PipelineDependencyTracker] — the opaque `ticket` a
/// [PendingPipelineDependency] hands back, to pass to
/// [AnswerTable.endPipelinedDependency] exactly once. Guards against a
/// caller bug (ending the same dependency twice), which would otherwise
/// silently corrupt [_PipelineDependencyTracker.dependentCount].
final class _PipelineDependencyTicket {
  final _PipelineDependencyTracker tracker;
  bool ended = false;
  _PipelineDependencyTicket(this.tracker);
}

/// What [AnswerTable.tryBeginPipelinedDependency] found for a promisedAnswer
/// target, exactly one of which applies.
sealed class PipelineDependency {
  const PipelineDependency();
}

/// The parent answer is already resolved: dispatch against [resolved]
/// immediately, no queuing and no matching [AnswerTable.endPipelinedDependency]
/// call needed.
final class ResolvedPipelineDependency extends PipelineDependency {
  final ResolvedAnswer resolved;
  const ResolvedPipelineDependency(this.resolved);
}

/// The parent answer's dispatch is still running: queue behind
/// [parentDispatchResult], and call [AnswerTable.endPipelinedDependency]
/// with [ticket] exactly once
/// this dependent is done with its eventual result (whether that result is
/// used successfully or the parent call fails) — never re-derive that call
/// from the parent's question id, which may have already been legally
/// reused by the peer for an unrelated new Call by the time this settles.
final class PendingPipelineDependency extends PipelineDependency {
  final Future<ResolvedAnswer> parentDispatchResult;
  final Object ticket;
  const PendingPipelineDependency(this.parentDispatchResult, this.ticket);
}

/// One incoming question's answer-lifecycle state, exactly one of which
/// applies at a time — see [AnswerTable]'s own doc comment for how
/// [TwoPartyRpcConnection] drives the transitions between them.
sealed class AnswerState {
  const AnswerState();
}

/// This question has an answer pending while its capability invocation is
/// still running. [dispatchResult] lets a pipelined call queue behind it;
/// [cancellation] lets a Finish that arrives before completion — and with
/// no pipelined dependents left outstanding — cancel the invocation. Every
/// pipelined call that queues behind [dispatchResult] (see
/// `AnswerTable.tryBeginPipelinedDependency`) is tracked in the private
/// dependency tracker below, which outlives this state object once the
/// dispatch settles — see `_PipelineDependencyTracker`'s own doc comment.
/// (Private, not exposed as a named field here, purely so this otherwise-
/// public class doesn't leak a private type through a public API.)
final class PendingAnswerState extends AnswerState {
  final Future<ResolvedAnswer> dispatchResult;
  final DispatchCancellationController cancellation;
  final _PipelineDependencyTracker _dependents = _PipelineDependencyTracker();
  PendingAnswerState(this.dispatchResult, this.cancellation);
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
/// still running, with no pipelined dependents left outstanding at the
/// time (see `PendingAnswerState`'s private dependency tracker) —
/// cancellation was notified immediately. The eventual dispatch result must
/// be dropped instead of resurrecting answer state for it; the caller
/// answers it with `Return(canceled)` instead once it settles (see
/// `IncomingCallCoordinator._sendCanceledReturn`).
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
/// release an export — [handlePeerFinish] only ever hands back the result
/// export ids
/// that need releasing; the caller (today, `IncomingCallCoordinator`) owns
/// translating that into an actual `ExportTable.releaseReference` call and
/// any wire traffic.
///
/// Lifecycle category: this table straddles both halves of an incoming
/// call's life. [PendingAnswerState.dispatchResult] (and the
/// [PendingPipelineDependency.parentDispatchResult] pipelined calls queue
/// behind) is **local** — it advances purely on this vat's own capability
/// dispatch settling, with no peer message required, so connection teardown
/// only *requests* cancellation (see [PendingAnswerState.cancellation]) and
/// a dispatch already running is free to keep running to completion. Once
/// dispatch settles into [AnsweredState], waiting for the peer's `Finish` is
/// **wire-driven** instead, exactly like `QuestionTable`'s `Return` wait.
/// Contrast both with `ImportTable.batchedReleaseImportCount`, which tracks
/// already-decided operations merely queued for a future wire send.
///
/// Every public member below is grouped, in order: **Query** (read-only
/// lookups), **Event** (`handleXxx` methods — each reports a fact about the
/// world to this table and lets it decide, from its own current state, what
/// the caller must now do; none of them are commands whose effect the
/// caller could predict without reading the return value), **Lifecycle**
/// (table-wide, not per-qid), and **Other** (pipeline-dependency tracking).
class AnswerTable {
  final Map<int, AnswerState> _answers = {};

  Object? _tearDownError;
  final List<Completer<Never>> _tearDownWaiters = [];

  // ---------------------------------------------------------------------
  // Query
  // ---------------------------------------------------------------------

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
  ResolvedAnswer? getResolvedAnswerFor(int qid) {
    final state = _answers[qid];
    return state is AnsweredState ? state.resolved : null;
  }

  /// The in-flight dispatch future for [qid], if it hasn't settled yet.
  Future<ResolvedAnswer>? getDispatchResultFor(int qid) {
    final state = _answers[qid];
    return state is PendingAnswerState ? state.dispatchResult : null;
  }

  /// The error [qid]'s dispatch failed with, if any — retained until Finish
  /// so a `takeFromOtherQuestion` racing with the failure still observes
  /// the original error rather than a misleading "unknown question id".
  CapnpException? getDispatchErrorFor(int qid) {
    final state = _answers[qid];
    return state is FailedAnswerState ? state.error : null;
  }

  // ---------------------------------------------------------------------
  // Event — each method below reports a fact to this table and returns
  // whatever the caller must now do about it; this table (not the caller)
  // decides the consequence from its own current state.
  // ---------------------------------------------------------------------

  /// Reports that dispatch has started for [qid]: [dispatchResult] lets a
  /// pipelined call queue behind the running capability invocation, and
  /// [cancellation] lets an early Finish cancel it.
  void handleDispatchStarted(
    int qid,
    Future<ResolvedAnswer> dispatchResult,
    DispatchCancellationController cancellation,
  ) {
    _answers[qid] = PendingAnswerState(dispatchResult, cancellation);
  }

  /// Reports that [qid]'s capability invocation succeeded. If Finish already
  /// arrived while the answer was pending and no pipelined dependents were
  /// ever registered for it, drops every trace of it and returns
  /// `(completed: false, answerStateRetained: false,
  /// releaseResultExportsAfterSend: null)` — the caller must then discard
  /// the dispatch's result instead of answering it, exactly like
  /// [handleDispatchSettledWithoutAnswer] reporting `true`.
  ///
  /// If Finish already arrived while dependents *were* still outstanding,
  /// this still returns `completed: true` — an ordinary Return should still
  /// be sent, since those dependents need the result — but frees [qid]
  /// immediately instead of waiting for a second Finish that will never
  /// arrive (the peer only ever sends one; `answerStateRetained: false`),
  /// and [releaseResultExportsAfterSend] carries [resultExportIds] if every
  /// dependent has *already* drained by this point (or `null` if some are
  /// still outstanding — see [endPipelinedDependency], which the caller
  /// must apply that same list from once it eventually returns non-null
  /// instead). Either way, the caller must apply a non-null
  /// [releaseResultExportsAfterSend] only *after* actually sending the
  /// Return, never before.
  ///
  /// Otherwise records [resolved]/[resultExportIds] as the answer awaiting
  /// Finish (see [handleAnswerWithoutDispatch], which this shares its
  /// recorded state with) and returns `(completed: true,
  /// answerStateRetained: true, releaseResultExportsAfterSend: null)`.
  ///
  /// [answerStateRetained] exists so a caller that goes on to send a
  /// `noFinishNeeded: true` Return knows whether it's still safe to follow
  /// up with [handleReturnSentWithNoFinishNeeded]`(qid)` afterward. Once
  /// that Return is on the wire, [qid]'s protocol lifecycle is over from
  /// the peer's perspective — `answerStateRetained: false` means this
  /// table already freed it *before* the send, so the peer may have
  /// legally (and, over a synchronously-reentrant transport, synchronously)
  /// reused it for an unrelated new Call by the time the caller's own send
  /// returns; a post-send [handleReturnSentWithNoFinishNeeded] call must be
  /// skipped in that case; a qid re-lookup at that point could otherwise
  /// touch the new call's own state instead — precisely the id-reuse hazard
  /// [endPipelinedDependency]'s ticket design exists to avoid, reintroduced
  /// if a caller re-derives its cleanup from the qid after the fact instead
  /// of this returned flag.
  ///
  /// Call this *before* actually sending the Return. Unlike calling
  /// [handleDispatchSettledWithoutAnswer] first and a separate call to
  /// record the answer second, this never leaves [qid] briefly untracked in
  /// between — a caller that sent the Return between those two calls would
  /// otherwise risk a synchronously-delivered Finish, duplicate Call, or
  /// pipelined Call for the same [qid] (e.g. over an in-memory or
  /// `sync: true` transport, where sending can reenter this table before
  /// the second call ever runs) observing state this table never actually
  /// held.
  ({
    bool completed,
    bool answerStateRetained,
    List<int>? releaseResultExportsAfterSend,
  })
  handleDispatchSucceeded(
    int qid, {
    ResolvedAnswer? resolved,
    List<int> resultExportIds = const [],
  }) {
    final state = _answers[qid];
    switch (state) {
      case FinishedBeforeCompletionState():
        _answers.remove(qid);
        return (
          completed: false,
          answerStateRetained: false,
          releaseResultExportsAfterSend: null,
        );
      case PendingAnswerState(:final _dependents) when _dependents.peerFinished:
        _dependents.resultExportIds = resultExportIds;
        final release = _dependents.tryTakeResultExports();
        _answers.remove(qid);
        return (
          completed: true,
          answerStateRetained: false,
          releaseResultExportsAfterSend: release,
        );
      default:
        _answers[qid] = AnsweredState(
          resolved: resolved,
          resultExportIds: resultExportIds,
        );
        return (
          completed: true,
          answerStateRetained: true,
          releaseResultExportsAfterSend: null,
        );
    }
  }

  /// Reports that [qid]'s capability invocation failed, with [error]
  /// retained for a racing `takeFromOtherQuestion` — only used on the
  /// sendResultsTo=yourself failure path, where nothing is put on the wire
  /// that a normal Return.exception would otherwise carry. Same atomicity
  /// contract as [handleDispatchSucceeded], including its
  /// early-Finish-with-dependents handling — a failure never carries result
  /// capabilities, so [releaseResultExportsAfterSend] is always empty or
  /// `null` here, never a real export id.
  ({bool completed, List<int>? releaseResultExportsAfterSend})
  handleDispatchFailed(int qid, CapnpException error) {
    final state = _answers[qid];
    switch (state) {
      case FinishedBeforeCompletionState():
        _answers.remove(qid);
        return (completed: false, releaseResultExportsAfterSend: null);
      case PendingAnswerState(:final _dependents) when _dependents.peerFinished:
        _dependents.resultExportIds = const [];
        final release = _dependents.tryTakeResultExports();
        _answers.remove(qid);
        return (completed: true, releaseResultExportsAfterSend: release);
      default:
        _answers[qid] = FailedAnswerState(error);
        return (completed: true, releaseResultExportsAfterSend: null);
    }
  }

  /// Reports that [qid]'s capability invocation settled on a path that
  /// records no further answer state (connection torn down, or a plain
  /// exception Return that needs no Finish): clears its pending-answer
  /// lifecycle and reports whether the peer already sent Finish while it
  /// was pending. When `true`, every trace of [qid] has already been
  /// dropped (a Finished answer must never be resurrected) and the caller
  /// must discard the dispatch's result instead of answering it with a
  /// normal Return — see `IncomingCallCoordinator._sendCanceledReturn`.
  ///
  /// A path that *does* go on to record an answer must use
  /// [handleDispatchSucceeded]/[handleDispatchFailed] instead — calling
  /// this first would still detect the early Finish correctly, but leaves
  /// [qid] briefly untracked in between, which a caller that then sends the
  /// Return before its own follow-up call can observe (see those methods'
  /// doc comments).
  bool handleDispatchSettledWithoutAnswer(int qid) {
    final state = _answers[qid];
    if (state case PendingAnswerState(
      :final _dependents,
    ) when _dependents.peerFinished) {
      // An exception Return never carries result capabilities, so there's
      // nothing this qid's dependents (if any) were ever waiting to use —
      // still resolve the tracker's rendezvous for hygiene (a no-op
      // release either way) rather than leaving it permanently
      // undetermined.
      _dependents.resultExportIds = const [];
      _dependents.tryTakeResultExports();
      _answers.remove(qid);
      return false;
    }
    final wasFinishedEarly = state is FinishedBeforeCompletionState;
    _answers.remove(qid);
    return wasFinishedEarly;
  }

  /// Reports that [qid] is answered and awaiting Finish, for a Return sent
  /// without ever going through a live dispatch (so no early-Finish race is
  /// possible — see [handleDispatchSucceeded] for the dispatch counterpart
  /// that must guard against one): a directly-resolved answer such as
  /// Bootstrap's ([resolved] set, no export ids of its own to release), or
  /// a Return with no result payload at all (an exception, or a
  /// takeFromOtherQuestion forward — neither [resolved] nor
  /// [resultExportIds] set).
  void handleAnswerWithoutDispatch(
    int qid, {
    ResolvedAnswer? resolved,
    List<int> resultExportIds = const [],
  }) {
    _answers[qid] = AnsweredState(
      resolved: resolved,
      resultExportIds: resultExportIds,
    );
  }

  /// Reports that a Return was just sent for [qid] with `noFinishNeeded:
  /// true`, clearing the completed answer bookkeeping accordingly.
  ///
  /// Only an [AnsweredState] with no result capabilities is valid here. A
  /// missing entry is also a no-op because synchronously sending the Return
  /// can reenter [handlePeerFinish], which may consume the state first —
  /// or, with an early-Finish-with-dependents answer, because
  /// [handleDispatchSucceeded] already removed [qid] itself before this is
  /// ever called. This never cancels a dispatch or releases an export.
  void handleReturnSentWithNoFinishNeeded(int qid) {
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

  /// Reports an incoming Finish for [qid], with [releaseResultCaps]
  /// carrying the wire message's own flag of the same name: drops its
  /// answer state and returns the result export ids to release, or `null`
  /// if there's nothing to release right now (either because [qid] has none
  /// to release, or because [releaseResultCaps] was `false`) — the caller
  /// is responsible for actually releasing them (see
  /// [ExportTable.releaseReference]; this only ever returns what needs it).
  ///
  /// Returns `null` if [qid]'s dispatch was still pending when Finish
  /// arrived. If no pipelined dependents were registered for it (see
  /// [tryBeginPipelinedDependency]), this cancels the dispatch immediately,
  /// exactly as before — the caller answers it with `Return(canceled)`
  /// once it settles (see [FinishedBeforeCompletionState]). If dependents
  /// *are* still outstanding, cancellation is deferred entirely: this just
  /// records [releaseResultCaps] on the pending answer's dependency
  /// tracker for [handleDispatchSucceeded]/[handleDispatchFailed] to apply
  /// once the dispatch actually settles, and the dispatch keeps running
  /// uncanceled so those dependents get a real result.
  ///
  /// Also returns `null` (as a no-op) if [qid] is unknown, or already
  /// marked finished by an earlier call — a Finish must never resurrect or
  /// double-cancel anything.
  List<int>? handlePeerFinish(int qid, {required bool releaseResultCaps}) {
    final state = _answers[qid];
    switch (state) {
      case null:
      case FinishedBeforeCompletionState():
        return null;
      case PendingAnswerState(:final _dependents, :final cancellation):
        if (_dependents.peerFinished) return null;
        _dependents.peerFinished = true;
        _dependents.releaseResultCapsOnFinish = releaseResultCaps;
        if (_dependents.dependentCount == 0) {
          _answers[qid] = const FinishedBeforeCompletionState();
          cancellation.cancel();
        }
        return null;
      case AnsweredState(:final resultExportIds):
        _answers.remove(qid);
        return releaseResultCaps ? resultExportIds : null;
      case FailedAnswerState():
        _answers.remove(qid);
        return null;
    }
  }

  // ---------------------------------------------------------------------
  // Lifecycle (table-wide, not per-qid)
  // ---------------------------------------------------------------------

  /// Number of teardown registrations [failOnTearDown] currently has
  /// outstanding — i.e. calls still racing [operation] against this table
  /// tearing down, neither having settled yet. Test/introspection only:
  /// this should return to `0` after every such race settles, whichever
  /// side wins; a value that only grows across many successful calls
  /// would mean [failOnTearDown] is leaking a registration per call
  /// instead of cleaning up its losing side.
  int get pendingTearDownRegistrationCount => _tearDownWaiters.length;

  /// Races [operation] against this table tearing down, resolving/failing
  /// with whichever finishes first — without needing to abort [operation]
  /// itself, which keeps running in the background regardless of which
  /// side of the race wins (see `DispatchCancellationController.cancel`,
  /// only ever a cooperative *request* a dispatch is free to ignore).
  ///
  /// Exists for a dispatch whose own settlement is being awaited directly
  /// rather than through this table's own Return/Finish bookkeeping —
  /// today, only `IncomingCallCoordinator.resolveLocalAnswer`'s
  /// `getDispatchResultFor(qid)` branch, used to correlate a peer's
  /// `Return.takeFromOtherQuestion` for a tail-called dispatch. Without
  /// this race, a caller like that would observe [operation] succeed from
  /// purely local state even *after* the connection that correlated it is
  /// already gone, unlike every other still-pending call on this
  /// connection (see `QuestionTable.tearDown`, which this is meant to
  /// match — see issue #99).
  ///
  /// The registration this needs internally to be notified once [tearDown]
  /// runs is torn down again the moment the race settles, *whichever side
  /// wins* — including when [operation] itself wins, the common/successful
  /// case — via `whenComplete`. A caller-visible "watch" handle the caller
  /// would need to remember to cancel was deliberately rejected in favor of
  /// this: leaving that lifecycle to a call site risks exactly the leak a
  /// missed `cancel()` would cause — one abandoned registration per
  /// successful call, for the lifetime of the connection — so it is kept
  /// entirely internal instead, impossible to forget from the outside.
  Future<T> failOnTearDown<T>(Future<T> operation) {
    final error = _tearDownError;
    if (error != null) return Future.error(error);
    final waiter = Completer<Never>();
    _tearDownWaiters.add(waiter);
    return Future.any<T>([
      operation,
      waiter.future,
    ]).whenComplete(() => _tearDownWaiters.remove(waiter));
  }

  /// Drops every tracked answer's state, canceling any still-live dispatch,
  /// and fails every outstanding (and future) [failOnTearDown] race with
  /// [error] — called once when the owning connection tears down.
  void tearDown(Object error) {
    for (final state in _answers.values) {
      if (state is PendingAnswerState) state.cancellation.cancel();
    }
    _answers.clear();
    if (_tearDownError == null) {
      _tearDownError = error;
      for (final waiter in _tearDownWaiters) {
        waiter.completeError(error);
      }
      // failOnTearDown's own `whenComplete` clears each entry as its race
      // settles — but that runs asynchronously (at least one microtask
      // after completeError above), so clearing eagerly here too avoids
      // this list holding already-losing Completers in the meantime.
      _tearDownWaiters.clear();
    }
  }

  // ---------------------------------------------------------------------
  // Other (pipeline-dependency tracking)
  // ---------------------------------------------------------------------

  /// Atomically checks whether [qid] is a valid promisedAnswer target for a
  /// brand-new pipelined call and, if its dispatch is still running,
  /// registers this call as a dependent so its eventual cancellation and
  /// result-export cleanup are deferred until every dependent registered
  /// this way has had a chance to use the result — pairs with
  /// [endPipelinedDependency], which the caller must invoke exactly once
  /// for every non-null [PendingPipelineDependency] this returns.
  ///
  /// Returns `null` when [qid] cannot be pipelined off at all right now:
  /// unknown, resolved with no capability payload of its own (e.g. an
  /// exception answer), failed, or — critically — already Finished by the
  /// peer. A Finished answer is never a valid target for a *new* pipelined
  /// call, even while it still has live dependents registered from before
  /// the Finish.
  PipelineDependency? tryBeginPipelinedDependency(int qid) {
    final state = _answers[qid];
    switch (state) {
      case AnsweredState(:final resolved):
        return resolved != null ? ResolvedPipelineDependency(resolved) : null;
      case PendingAnswerState(:final dispatchResult, :final _dependents):
        if (_dependents.peerFinished) return null;
        _dependents.dependentCount++;
        return PendingPipelineDependency(
          dispatchResult,
          _PipelineDependencyTicket(_dependents),
        );
      case FailedAnswerState():
      case FinishedBeforeCompletionState():
      case null:
        return null;
    }
  }

  /// Ends one dependency [tryBeginPipelinedDependency] began, identified by
  /// the opaque [ticket] it returned — regardless of whether this
  /// dependent's own call ultimately succeeds or fails. Never looks
  /// anything up by question id: the ticket carries its own reference to
  /// the answer's dependency tracker directly, so this remains correct
  /// even if the owning qid has since been freed and legally reused by the
  /// peer for an unrelated new Call.
  ///
  /// Returns the result export ids to release now, if this was the last
  /// outstanding dependent *and* the parent's own settle-time bookkeeping
  /// has already recorded them *and* the peer's Finish requested their
  /// release — `null` otherwise (including when this dependent drains
  /// before the parent has settled: the caller side of that rendezvous,
  /// [handleDispatchSucceeded]/[handleDispatchFailed], hands back the same
  /// list once it's the one to satisfy the last condition instead).
  ///
  /// Throws [StateError] if [ticket] was already ended once — a caller bug
  /// that would otherwise silently corrupt the dependent count.
  List<int>? endPipelinedDependency(Object ticket) {
    final t = ticket as _PipelineDependencyTicket;
    if (t.ended) {
      throw StateError('pipeline dependency ticket already ended');
    }
    t.ended = true;
    final tracker = t.tracker;
    tracker.dependentCount--;
    assert(tracker.dependentCount >= 0);
    return tracker.tryTakeResultExports();
  }
}
