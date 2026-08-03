/// Outgoing-call construction and sending: target/params resolution,
/// capTable encoding for a fresh Call, question tracking, and handling
/// the matching Return once it arrives. Moved out of
/// [TwoPartyRpcConnection] verbatim -- see that class's own doc comment.

part of 'two_party_connection.dart';

extension _OutgoingCallFlow on TwoPartyRpcConnection {
  /// True when starting a Call against [target] needs to `await` something
  /// before any side effect (an export refcount bump, `_sendRaw`) can run —
  /// see [_resolveCapTableMaybeSync]'s matching doc comment for why this
  /// must be checked before touching anything with a side effect.
  bool _targetNeedsAsync(OutgoingCallTarget target) => switch (target) {
    ImportedCapabilityTarget(importId: final id) => id is! int,
    PromisedAnswerTarget(questionId: final qid) =>
      _questionTable.sentCompleterFor(qid) != null,
  };

  /// Builds an outgoing Call's wire bytes against [target]/[params],
  /// synchronously when possible (mirrors the old `_startResolvedImportCall`
  /// fast path: no `Future`/microtask indirection when [target]'s import id
  /// is already known and [paramsCapabilities] resolves synchronously) and
  /// asynchronously otherwise, via [_buildOutgoingCallBytesAsync].
  FutureOr<Uint8List> _buildOutgoingCallBytes({
    required int qid,
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    required List<Capability> paramsCapabilities,
    bool sendResultsToYourself = false,
  }) {
    final buildParams = switch (params) {
      SerializedParams(bytes: final b) =>
        (AnyPointerBuilder p) =>
            p.setMessageBytes(b, preserveCapabilityPointers: true),
      BuilderParams(build: final b) => b,
    };

    if (_targetNeedsAsync(target)) {
      return _buildOutgoingCallBytesAsync(
        qid: qid,
        target: target,
        buildParams: buildParams,
        interfaceId: interfaceId,
        methodId: methodId,
        paramsCapabilities: paramsCapabilities,
        sendResultsToYourself: sendResultsToYourself,
      );
    }

    int targetImportId = 0;
    int? targetPromisedAnswerQid;
    var targetTransformPath = const <int>[];
    switch (target) {
      case ImportedCapabilityTarget(importId: final id):
        targetImportId = id as int; // _targetNeedsAsync confirmed this above
        _importTable.throwIfBroken(targetImportId);
      case PromisedAnswerTarget(
        questionId: final pqid,
        transformPath: final path,
      ):
        targetPromisedAnswerQid = pqid;
        targetTransformPath = path;
    }
    return buildCallMessageBuildingMaybeSync(
      questionId: qid,
      targetImportId: targetImportId,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetTransformPath: targetTransformPath,
      interfaceId: interfaceId,
      methodId: methodId,
      buildParams: buildParams,
      resolveDescriptors:
          () => _resolveCapTableMaybeSync(paramsCapabilities, qid: qid),
      sendResultsToYourself: sendResultsToYourself,
    );
  }

  /// Async branch of [_buildOutgoingCallBytes] — awaits whatever [target]
  /// needs (an import id, or the promisedAnswer target's parent being sent),
  /// then resolves the capTable.
  ///
  /// Uses [buildCallMessageBuilding] (a `resolveCapTable` callback invoked
  /// only *after* [buildParams] has returned), not a pre-resolve-then-sync-
  /// build sequence: [paramsCapabilities] may still be being appended to by
  /// [buildParams] itself for a builder-based Call (see [Capability.
  /// dispatchBuilding]'s contract) — resolving the capTable before
  /// [buildParams] runs would silently miss those. This is safe and
  /// equivalent for a serialized-params Call too, since the synthetic
  /// `setMessageBytes` [buildParams] built by [_buildOutgoingCallBytes]
  /// never appends to [paramsCapabilities].
  Future<Uint8List> _buildOutgoingCallBytesAsync({
    required int qid,
    required OutgoingCallTarget target,
    required void Function(AnyPointerBuilder) buildParams,
    required int interfaceId,
    required int methodId,
    required List<Capability> paramsCapabilities,
    required bool sendResultsToYourself,
  }) async {
    int targetImportId = 0;
    int? targetPromisedAnswerQid;
    var targetTransformPath = const <int>[];
    switch (target) {
      case ImportedCapabilityTarget(importId: final id):
        targetImportId = id is int ? id : await id;
        _importTable.throwIfBroken(targetImportId);
      case PromisedAnswerTarget(
        questionId: final pqid,
        transformPath: final path,
      ):
        // For promisedAnswer targets, wait until the parent Call is on the
        // wire so the server always receives the parent before the
        // pipelined call.
        final parentSent = _questionTable.sentCompleterFor(pqid);
        if (parentSent != null) await parentSent.future;
        targetPromisedAnswerQid = pqid;
        targetTransformPath = path;
    }
    return buildCallMessageBuilding(
      questionId: qid,
      targetImportId: targetImportId,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetTransformPath: targetTransformPath,
      interfaceId: interfaceId,
      methodId: methodId,
      buildParams: buildParams,
      resolveCapTable:
          () async =>
              await _resolveCapTableMaybeSync(paramsCapabilities, qid: qid),
      sendResultsToYourself: sendResultsToYourself,
    );
  }

  /// The single site wiring [QuestionTable.markSent] (on success) and
  /// [QuestionTable.failBeforeSend] + [_applyReleaseParamCaps] (on failure)
  /// together for an outgoing Call — shared by [_startOutgoingCall] and
  /// [_sendTailForwardCall], so this pairing is never wired up ad hoc at a
  /// third call site. Every path that reaches [onError] does so before
  /// `_sendRaw` ever runs (nothing after that point in [_buildOutgoingCallBytes]/
  /// [_buildOutgoingCallBytesAsync] can throw) — any params export refs
  /// already bumped for [question] never actually reached the peer and must
  /// be rolled back here.
  void _sendOutgoingCall({
    required OutgoingQuestion question,
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    required List<Capability> paramsCapabilities,
    bool sendResultsToYourself = false,
  }) {
    final qid = question.id;
    void onError(Object e, StackTrace st) {
      final ids = _questionTable.failBeforeSend(question, e, st);
      if (ids != null) _applyReleaseParamCaps(ids);
    }

    try {
      final builtOrFuture = _buildOutgoingCallBytes(
        qid: qid,
        target: target,
        params: params,
        interfaceId: interfaceId,
        methodId: methodId,
        paramsCapabilities: paramsCapabilities,
        sendResultsToYourself: sendResultsToYourself,
      );
      if (builtOrFuture is Uint8List) {
        _sendRaw(builtOrFuture);
        _questionTable.markSent(qid);
      } else {
        builtOrFuture.then((bytes) {
          _sendRaw(bytes);
          _questionTable.markSent(qid);
        }, onError: onError);
      }
    } catch (e, st) {
      onError(e, st);
    }
  }

  /// Starts an outgoing Call against [target] with [params]. Allocates a
  /// question ID immediately (available synchronously for pipelining, via
  /// [StartedCall.questionId]), then builds and sends the Call message —
  /// synchronously when possible, asynchronously otherwise — via
  /// [_sendOutgoingCall]. [StartedCall.result] resolves once the matching
  /// Return arrives.
  StartedCall _startOutgoingCall({
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    List<Capability> paramsCapabilities = const [],
  }) {
    if (_closedError != null) {
      throw RpcException('connection is closed', kind: ErrorKind.disconnected);
    }
    // Mirrors the old _startResolvedImportCall's up-front check: a broken
    // import already known synchronously throws immediately, before a
    // question id is even allocated. An import id that still needs
    // awaiting, or a promisedAnswer target, is checked later instead, once
    // _buildOutgoingCallBytes[Async] actually reaches it.
    if (target case ImportedCapabilityTarget(
      importId: final id,
    ) when id is int) {
      _importTable.throwIfBroken(id);
    }

    final question = _questionTable.allocate();
    question.sentCompleter!.future.ignore();

    _sendOutgoingCall(
      question: question,
      target: target,
      params: params,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );

    return StartedCall(
      question.id,
      _awaitReturn(question.id, question.returnCompleter!),
    );
  }

  Future<DispatchResult> _awaitReturn(
    int qid,
    Completer<RpcMessage> completer,
  ) async {
    final RpcMessage ret;
    final List<int>? paramExportIds;
    try {
      ret = await completer.future;
    } finally {
      // Whether or not a params-caps entry was ever recorded for this qid
      // (see _recordParamExportIds), drop it now — nothing past this point
      // reads _questionParamExportIds[qid] again, on any path (success,
      // exception, or completer failing before a Return ever arrived).
      // Captured into a local first so the success path below still has it
      // even though `finally` runs before that code does.
      paramExportIds = _questionTable.takeParamExportIds(qid);
    }

    // Only Return-results/Return-exception ever legitimately carry these —
    // see RpcMessage.returnReleaseParamCaps/returnNoFinishNeeded's doc
    // comment. releaseParamCaps applying to an exception Return, not just
    // results, mirrors buildReturnExceptionMessage's own support for it.
    final answersCall = ret.isReturnResults || ret.isReturnException;
    if (answersCall && ret.returnReleaseParamCaps && paramExportIds != null) {
      _applyReleaseParamCaps(paramExportIds);
    }
    if (!(answersCall && ret.returnNoFinishNeeded)) {
      _sendRaw(buildFinishMessage(qid, releaseResultCaps: false));
    }

    if (ret.isReturnException) {
      throw RpcException(
        ret.exceptionReason ?? 'remote exception',
        kind: ret.exceptionKind,
      );
    }
    if (ret.isReturnTakeFromOtherQuestion) {
      // The peer tail-called this call onward to a capability it imports
      // from us — i.e. back to a capability WE host. The real answer is
      // therefore already tracked, locally, under our own incoming-answer
      // bookkeeping for that forwarded call: no extra wire round trip
      // needed to fetch it.
      final resolved = await _resolveLocalAnswer(ret.takeFromOtherQuestion);
      return DispatchResult(
        payload: RpcPayload.fromBytes(resolved.resultBytes),
        caps: resolved.caps,
      );
    }
    if (!ret.isReturnResults) {
      // canceled / resultsSentElsewhere / acceptFromThirdParty — none of
      // these are implemented by this vat. Surfacing them as an explicit
      // error is important specifically for resultsSentElsewhere: it's only
      // ever valid as the Return to a call *we* sent with
      // sendResultsTo=yourself (see _sendTailForwardCall, which never routes
      // through _awaitReturn), so seeing it here means a peer sent it
      // unprompted — treating it as an empty success would silently hand
      // the caller a bogus empty-struct result instead of the real one.
      throw RpcException(
        'unsupported Return variant: ${describeReturnDisc(ret.returnDisc)}',
      );
    }

    // Convert capTable entries into ImportedCapabilities.
    final caps = <Capability>[];
    for (final descriptor in ret.capTableDescriptors) {
      caps.add(_capabilityFromDescriptor(descriptor));
    }

    final resultsContent = ret.resultsContent;
    return DispatchResult(
      payload:
          resultsContent != null
              ? RpcPayload.fromEnvelope(resultsContent)
              : RpcPayload.fromBytes(TwoPartyRpcConnection._emptyResultBytes),
      caps: caps,
    );
  }

  void _handleReturn(RpcMessage msg) {
    final completer = _questionTable.takeReturn(msg.answerId);
    if (completer == null) return;

    // Only drive the bootstrap completer for the bootstrap question itself.
    if (msg.answerId == _bootstrapQuestionId) {
      final bootstrapQid = _bootstrapQuestionId!;
      _bootstrapQuestionId = null;
      if (msg.isReturnResults && msg.capTableEntries.isNotEmpty) {
        final importId = _importIdFromDescriptor(msg.capTableDescriptors.first);
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          if (importId == null) {
            _bootstrapCompleter!.completeError(
              const RpcException(
                'bootstrap Return cap table entry was not an import',
              ),
            );
          } else {
            _bootstrapCompleter!.complete(importId);
          }
        }
      } else if (msg.isReturnException) {
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          _bootstrapCompleter!.completeError(
            RpcException(
              msg.exceptionReason ?? 'bootstrap failed',
              kind: msg.exceptionKind,
            ),
          );
        }
      } else {
        if (_bootstrapCompleter != null && !_bootstrapCompleter!.isCompleted) {
          _bootstrapCompleter!.completeError(
            const RpcException(
              'bootstrap Return had no capability in cap table',
            ),
          );
        }
      }
      // Send Finish to release the server's answer state for this Bootstrap
      // question. releaseResultCaps=false because the client is retaining the
      // imported bootstrap capability.
      _sendRaw(buildFinishMessage(bootstrapQid, releaseResultCaps: false));
    }

    if (!completer.isCompleted) {
      completer.complete(msg);
    }
  }
}
