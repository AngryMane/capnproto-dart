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
final class OutgoingQuestion {
  final int id;
  Completer<RpcMessage>? returnCompleter;
  Completer<void>? sentCompleter;
  List<int>? parameterExportIds;

  OutgoingQuestion({
    required this.id,
    required this.returnCompleter,
    this.sentCompleter,
    this.parameterExportIds,
  });
}

class QuestionTable {
  final Map<int, OutgoingQuestion> _questions = {};
  int _nextQuestionId = 0;

  /// Number of outgoing questions still awaiting their `Return`.
  int get pendingCount =>
      _questions.values.where((q) => q.returnCompleter != null).length;

  /// Number of outgoing questions whose Call hasn't reached the wire yet.
  int get pendingSentCount =>
      _questions.values.where((q) => q.sentCompleter != null).length;

  /// Allocates a fresh question id and registers a `Return` completer for
  /// it, without any matching sent-tracking — used only by `bootstrap()`,
  /// whose Bootstrap message is built and sent synchronously in the same
  /// breath (nothing ever pipelines off of it, so there's no "has this
  /// reached the wire yet" question to answer).
  OutgoingQuestion allocateForBootstrap() {
    final qid = _nextQuestionId++;
    final question = OutgoingQuestion(
      id: qid,
      returnCompleter: Completer<RpcMessage>(),
    );
    _questions[qid] = question;
    return question;
  }

  /// Allocates a fresh question id plus its matching `Return` completer and
  /// sent completer — used by every real outgoing Call (`_startCall`,
  /// `_startResolvedImportCall`, `_startCallBuilding`,
  /// `_sendTailForwardCall`).
  OutgoingQuestion allocate() {
    final qid = _nextQuestionId++;
    final question = OutgoingQuestion(
      id: qid,
      returnCompleter: Completer<RpcMessage>(),
      sentCompleter: Completer<void>(),
    );
    _questions[qid] = question;
    return question;
  }

  /// The sent completer for [qid], if its Call hasn't reached the wire yet
  /// — used to make a promisedAnswer-target Call, or a receiverAnswer param
  /// capability referencing [qid], wait for it to be sent first.
  Completer<void>? sentCompleterFor(int qid) => _questions[qid]?.sentCompleter;

  /// Marks [qid]'s Call as sent: completes its sent completer (if not
  /// already) and drops sent-tracking for it — nothing waits on it again
  /// past this point.
  void markSent(int qid) {
    final question = _questions[qid];
    final sentCompleter = question?.sentCompleter;
    if (sentCompleter != null && !sentCompleter.isCompleted) {
      sentCompleter.complete();
    }
    if (question != null) {
      question.sentCompleter = null;
    }
  }

  /// Drops [qid]'s tracking entirely — its Call failed to build/send, so
  /// there is no `Return` to ever await and nothing further to wait to be
  /// sent. Callers still complete the object's completers with the failure
  /// themselves.
  void abandon(int qid) {
    _questions.remove(qid);
  }

  /// Records the senderHosted/senderPromise export ids among an outgoing
  /// Call's own capTable (this vat's params capabilities) against [qid], so
  /// a later `Return.releaseParamCaps` can be applied locally once the
  /// matching Return arrives. A no-op for an empty [ids] — nothing to release either way.
  void recordParamExportIds(int qid, List<int> ids) {
    if (ids.isNotEmpty) {
      _questions[qid]?.parameterExportIds = ids;
    }
  }

  /// Removes and returns [qid]'s recorded params export ids, if any —
  /// called at most once per question, either to roll them back (the Call
  /// never reached the wire) or to apply `Return.releaseParamCaps` (it did,
  /// and a `Return` arrived).
  List<int>? takeParamExportIds(int qid) {
    final question = _questions[qid];
    if (question == null) return null;
    final ids = question.parameterExportIds;
    question.parameterExportIds = null;
    _removeIfEmpty(question);
    return ids;
  }

  void _removeIfEmpty(OutgoingQuestion question) {
    if (question.returnCompleter == null &&
        question.sentCompleter == null &&
        question.parameterExportIds == null) {
      _questions.remove(question.id);
    }
  }

  /// Removes and returns [qid]'s `Return` completer, if it's still tracked
  /// — `null` if [qid] is unknown (a stray/duplicate `Return`, or one for a
  /// question already torn down).
  Completer<RpcMessage>? takeReturn(int qid) {
    final question = _questions[qid];
    if (question == null) return null;
    final completer = question.returnCompleter;
    question.returnCompleter = null;
    _removeIfEmpty(question);
    return completer;
  }

  /// Removes and returns the question object for [qid], if it's still
  /// tracked.
  OutgoingQuestion? remove(int qid) => _questions.remove(qid);

  /// Fails [question] with [err] before it ever reaches the wire, clears its
  /// tracking, and returns any recorded parameter export ids that must be
  /// rolled back.
  List<int>? failBeforeSend(
    OutgoingQuestion question,
    Object err,
    StackTrace st,
  ) {
    final tracked = _questions.remove(question.id);
    if (tracked == null) return null;
    final sentCompleter = tracked.sentCompleter;
    if (sentCompleter != null && !sentCompleter.isCompleted) {
      sentCompleter.completeError(err, st);
    }
    final returnCompleter = tracked.returnCompleter;
    if (returnCompleter != null && !returnCompleter.isCompleted) {
      returnCompleter.completeError(err, st);
    }
    return tracked.parameterExportIds;
  }

  /// Fails every still-pending question (both awaiting-Return and
  /// awaiting-sent) with [err] and clears all tracking — called once when
  /// the owning connection tears down.
  void tearDown(Object err) {
    for (final entry in _questions.values) {
      final returnCompleter = entry.returnCompleter;
      if (returnCompleter != null && !returnCompleter.isCompleted) {
        returnCompleter.future.ignore();
        returnCompleter.completeError(err);
      }
      final sentCompleter = entry.sentCompleter;
      if (sentCompleter != null && !sentCompleter.isCompleted) {
        sentCompleter.completeError(err);
      }
    }
    _questions.clear();
  }
}
