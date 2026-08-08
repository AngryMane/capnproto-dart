import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../../capability/capability.dart'
    show Capability, DispatchCancellationController;

/// Pointer slots in [resultBytes] map to [caps] indices via a
/// `CapabilityPointer`, not by slot number — `IncomingCallCoordinator` must
/// parse the pointer to resolve a pipelined call against this.
class ResolvedAnswer {
  final Uint8List resultBytes;
  final List<Capability> caps;
  ResolvedAnswer(this.resultBytes, this.caps);
}

/// Outlives the question id it was created under once this vat sends its
/// own Return for it — see [AnswerTable.endPipelinedDependency].
final class _PipelineDependencyTracker {
  int dependentCount = 0;
  bool peerFinished = false;

  /// Only meaningful once [peerFinished] is true.
  bool releaseResultCapsOnFinish = true;

  /// `null` means not yet determined, distinct from "determined, empty".
  List<int>? resultExportIds;

  bool _resultReleaseTaken = false;

  /// Safe to call from either side of the [dependentCount]-draining vs.
  /// [resultExportIds]-recording race, in any order.
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

/// No queuing, and no matching [AnswerTable.endPipelinedDependency] call
/// needed.
final class ResolvedPipelineDependency extends PipelineDependency {
  final ResolvedAnswer resolved;
  const ResolvedPipelineDependency(this.resolved);
}

/// Call [AnswerTable.endPipelinedDependency] with [ticket] exactly once
/// regardless of outcome — never re-derive the call from the parent's
/// question id, which may already be legally reused by the peer for an
/// unrelated new Call by the time this settles.
final class PendingPipelineDependency extends PipelineDependency {
  final Future<ResolvedAnswer> parentDispatchResult;
  final Object ticket;
  const PendingPipelineDependency(this.parentDispatchResult, this.ticket);
}

/// One incoming question's answer-lifecycle state, exactly one of which
/// applies at a time.
sealed class AnswerState {
  const AnswerState();
}

/// [cancellation] only fires with no pipelined dependents left outstanding
/// — see [AnswerTable.handleRequesterFinishedAnswer]. [retainForLocalLookup]:
/// see [AnswerTable.handleDispatchStarted].
final class PendingAnswerState extends AnswerState {
  final Future<ResolvedAnswer> dispatchResult;
  final DispatchCancellationController cancellation;
  final bool retainForLocalLookup;
  final _PipelineDependencyTracker _dependents = _PipelineDependencyTracker();
  PendingAnswerState(
    this.dispatchResult,
    this.cancellation, {
    this.retainForLocalLookup = false,
  });
}

/// Installed *before* the Return is sent (see
/// [AnswerTable.handleDispatchSucceeded]), so this does not mean the Return
/// already went out — only that the answer itself is fixed. [resolved] is
/// null for a Return with no result payload of its own (an exception, or a
/// takeFromOtherQuestion forward).
final class AnsweredState extends AnswerState {
  final ResolvedAnswer? resolved;
  final List<int> resultExportIds;
  const AnsweredState({this.resolved, this.resultExportIds = const []});
}

/// The error is retained — rather than just sent as Return.exception and
/// forgotten — so a `takeFromOtherQuestion` racing the failure still
/// observes it instead of "unknown question id".
final class FailedAnswerState extends AnswerState {
  final CapnpException error;
  const FailedAnswerState(this.error);
}

/// Reached only with no pipelined dependents outstanding at Finish time —
/// cancellation was notified immediately. The eventual result is
/// discarded; caller answers with `Return(canceled)` once it settles (see
/// `IncomingCallCoordinator._sendCanceledReturn`).
final class FinishedBeforeCompletionState extends AnswerState {
  const FinishedBeforeCompletionState();
}

/// What [AnswerTable.handleDispatchSucceeded]/[AnswerTable.handleDispatchFailed]
/// need their caller to do about answering [qid], now that its dispatch has
/// settled — exactly one of which applies. [handleDispatchSucceeded] never
/// returns [AnswerDiscarded]: a successful dispatch always has an answer
/// worth recording.
sealed class DispatchSettlement {
  const DispatchSettlement();
}

/// Caller answers with `Return(canceled)` instead of a normal Return (see
/// `IncomingCallCoordinator._sendCanceledReturn`).
final class AnswerAlreadyFinished extends DispatchSettlement {
  const AnswerAlreadyFinished();
}

final class AnswerSettled extends DispatchSettlement {
  /// Only non-null when the peer's own early Finish already determined
  /// this while dependents were still outstanding. Apply only *after* the
  /// Return has actually been sent.
  final List<int>? releaseResultExportsAfterSend;

  const AnswerSettled({this.releaseResultExportsAfterSend});
}

/// See [PendingAnswerState.retainForLocalLookup] for why.
final class AnswerDiscarded extends DispatchSettlement {
  const AnswerDiscarded();
}

/// Invalid combinations (e.g. a retained error alongside a live dispatch)
/// can't be constructed through this table's API. Doesn't send
/// Returns/Finishes or release exports itself — the caller (today,
/// `IncomingCallCoordinator`) acts on what each method returns.
///
/// [PendingAnswerState.dispatchResult] is **local**: it settles purely
/// from this vat's own capability dispatch, so connection teardown only
/// *requests* cancellation. Once settled into [AnsweredState], waiting for
/// the peer's Finish is **wire-driven** instead, like `QuestionTable`'s
/// Return wait.
class AnswerTable {
  final Map<int, AnswerState> _answers = {};

  /// Independent of [_answers]: a real Finish only removes the requester's
  /// own reference to [qid] there, but this same vat's later local lookup
  /// (via [takeLocalLookupResolved]/[takeLocalLookupError]) is a separate
  /// reason to retain the outcome, on its own lifecycle — see
  /// [PendingAnswerState.retainForLocalLookup].
  final Map<int, ResolvedAnswer> _localLookupResolved = {};
  final Map<int, CapnpException> _localLookupErrors = {};

  Object? _tearDownError;
  final List<Completer<Never>> _tearDownWaiters = [];

  // ---------------------------------------------------------------------
  // Query
  // ---------------------------------------------------------------------

  int get count => _answers.length;

  int get cancellationCount =>
      _answers.values.whereType<PendingAnswerState>().length;

  /// Used to reject a peer illegally reusing a question id before it has
  /// fully settled.
  bool isTracked(int qid) => _answers.containsKey(qid);

  ResolvedAnswer? getResolvedAnswerFor(int qid) {
    final state = _answers[qid];
    return state is AnsweredState ? state.resolved : null;
  }

  Future<ResolvedAnswer>? getDispatchResultFor(int qid) {
    final state = _answers[qid];
    return state is PendingAnswerState ? state.dispatchResult : null;
  }

  CapnpException? getDispatchErrorFor(int qid) {
    final state = _answers[qid];
    return state is FailedAnswerState ? state.error : null;
  }

  /// One-shot: consumes and removes the entry, independent of whether a
  /// real Finish has already removed [qid] from the normal answer state —
  /// see [PendingAnswerState.retainForLocalLookup].
  ResolvedAnswer? takeLocalLookupResolved(int qid) =>
      _localLookupResolved.remove(qid);

  /// One-shot counterpart of [takeLocalLookupResolved] for a failed
  /// dispatch.
  CapnpException? takeLocalLookupError(int qid) =>
      _localLookupErrors.remove(qid);

  // ---------------------------------------------------------------------
  // Event — each method below reports a fact to this table and returns
  // whatever the caller must now do about it; this table (not the caller)
  // decides the consequence from its own current state.
  // ---------------------------------------------------------------------

  /// [retainForLocalLookup]: `true` means this same vat may itself still
  /// need to look up the eventual result or error later, through
  /// `takeFromOtherQuestion`/`resolveLocalAnswer` (see
  /// [takeLocalLookupResolved]/[takeLocalLookupError]) — today, exactly
  /// when this call was itself a forwarded tail call
  /// (`sendResultsTo=yourself`).
  void handleDispatchStarted(
    int qid,
    Future<ResolvedAnswer> dispatchResult,
    DispatchCancellationController cancellation, {
    bool retainForLocalLookup = false,
  }) {
    _answers[qid] = PendingAnswerState(
      dispatchResult,
      cancellation,
      retainForLocalLookup: retainForLocalLookup,
    );
  }

  /// Call this *before* sending the Return: sending first and recording
  /// this separately would risk a synchronously-delivered Finish, duplicate
  /// Call, or pipelined Call (e.g. over an in-memory or `sync: true`
  /// transport) observing state this table never held.
  DispatchSettlement handleDispatchSucceeded(
    int qid, {
    ResolvedAnswer? resolved,
    List<int> resultExportIds = const [],
  }) {
    final state = _answers[qid];
    switch (state) {
      case FinishedBeforeCompletionState():
        _answers.remove(qid);
        return const AnswerAlreadyFinished();
      case PendingAnswerState(:final _dependents, :final retainForLocalLookup)
          when _dependents.peerFinished:
        _dependents.resultExportIds = resultExportIds;
        final release = _dependents.tryTakeResultExports();
        _answers.remove(qid);
        if (retainForLocalLookup && resolved != null) {
          _localLookupResolved[qid] = resolved;
        }
        return AnswerSettled(releaseResultExportsAfterSend: release);
      case PendingAnswerState(:final retainForLocalLookup):
        final stillNeeded =
            retainForLocalLookup ||
            resultExportIds.isNotEmpty ||
            (resolved?.caps.isNotEmpty ?? false);
        if (stillNeeded) {
          _answers[qid] = AnsweredState(
            resolved: resolved,
            resultExportIds: resultExportIds,
          );
        } else {
          _answers.remove(qid);
        }
        if (retainForLocalLookup && resolved != null) {
          _localLookupResolved[qid] = resolved;
        }
        return const AnswerSettled();
      default:
        _answers[qid] = AnsweredState(
          resolved: resolved,
          resultExportIds: resultExportIds,
        );
        return const AnswerSettled();
    }
  }

  /// Same atomicity contract as [handleDispatchSucceeded]. A failure has no
  /// peer-visible Finish/pipelining need of its own, so
  /// [PendingAnswerState.retainForLocalLookup] is the only reason to retain
  /// it as a [FailedAnswerState] instead of discarding outright.
  DispatchSettlement handleDispatchFailed(int qid, CapnpException error) {
    final state = _answers[qid];
    switch (state) {
      case FinishedBeforeCompletionState():
        _answers.remove(qid);
        return const AnswerAlreadyFinished();
      case PendingAnswerState(:final _dependents, :final retainForLocalLookup)
          when _dependents.peerFinished:
        _dependents.resultExportIds = const [];
        final release = _dependents.tryTakeResultExports();
        _answers.remove(qid);
        if (retainForLocalLookup) {
          _localLookupErrors[qid] = error;
        }
        return AnswerSettled(releaseResultExportsAfterSend: release);
      case PendingAnswerState(retainForLocalLookup: true):
        _answers[qid] = FailedAnswerState(error);
        _localLookupErrors[qid] = error;
        return const AnswerSettled();
      default:
        _answers.remove(qid);
        return const AnswerDiscarded();
    }
  }

  /// So no early-Finish race is possible (contrast [handleDispatchSucceeded],
  /// which must guard against one): a directly-resolved answer such as
  /// Bootstrap's, or a Return with no result payload at all (exception, or
  /// takeFromOtherQuestion forward). Every current caller's Return
  /// genuinely still owes the peer a Finish.
  void handleAnswerReadyWithoutDispatch(
    int qid, {
    ResolvedAnswer? resolved,
    List<int> resultExportIds = const [],
  }) {
    _answers[qid] = AnsweredState(
      resolved: resolved,
      resultExportIds: resultExportIds,
    );
  }

  /// Named for *who* finished, not the Answer's own lifecycle: a
  /// still-outstanding pipelined dependent can keep this question's
  /// bookkeeping alive well past this call.
  List<int>? handleRequesterFinishedAnswer(
    int qid, {
    required bool releaseResultCaps,
  }) {
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

  /// Test/introspection only: should return to `0` after every
  /// [failOnTearDown] race settles, whichever side wins.
  int get pendingTearDownRegistrationCount => _tearDownWaiters.length;

  /// [operation] itself keeps running either way; cancellation
  /// (`DispatchCancellationController.cancel`) is only ever a cooperative
  /// request a dispatch is free to ignore, so this is the only way to stop
  /// *waiting* on it.
  ///
  /// Used where a dispatch's settlement is awaited directly, bypassing this
  /// table's own Return/Finish bookkeeping — today, only
  /// `IncomingCallCoordinator.resolveLocalAnswer`, resolving a
  /// `takeFromOtherQuestion` for a tail-called dispatch. Without it, that
  /// caller would observe [operation] succeed from purely
  /// local state even after the connection is gone (issue #99, matching
  /// `QuestionTable.tearDown`).
  ///
  /// Deliberately has no caller-visible "watch" handle to cancel — that
  /// would risk a leaked registration per call if a caller forgot.
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

  /// Fails every outstanding *and future* [failOnTearDown] race with
  /// [error] — called once when the owning connection tears down.
  void tearDown(Object error) {
    for (final state in _answers.values) {
      if (state is PendingAnswerState) state.cancellation.cancel();
    }
    _answers.clear();
    _localLookupResolved.clear();
    _localLookupErrors.clear();
    if (_tearDownError == null) {
      _tearDownError = error;
      for (final waiter in _tearDownWaiters) {
        waiter.completeError(error);
      }
      _tearDownWaiters.clear();
    }
  }

  // ---------------------------------------------------------------------
  // Pipelining (pipeline-dependency tracking)
  // ---------------------------------------------------------------------

  /// Registers this call as a dependent if [qid]'s dispatch is still
  /// running, deferring its cancellation/export cleanup — pairs with
  /// [endPipelinedDependency] (see [PendingPipelineDependency]'s own doc
  /// for the exactly-once contract).
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

  /// [ticket] carries its own reference, so this remains correct even if
  /// the owning qid has since been reused — see
  /// [_PipelineDependencyTracker.tryTakeResultExports] for when this
  /// returns non-null.
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
