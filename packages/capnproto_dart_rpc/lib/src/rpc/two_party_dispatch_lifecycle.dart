/// Answer lifecycle once a dispatch has started: running it (with
/// cancellation and tail-call support), building/sending its Return,
/// and Finish handling. Moved out of [TwoPartyRpcConnection] verbatim --
/// see that class's own doc comment.

part of 'two_party_connection.dart';

extension _DispatchLifecycle on TwoPartyRpcConnection {
  /// Resolves [qid] against this vat's own incoming-answer bookkeeping, for
  /// correlating a `Return.takeFromOtherQuestion` from the peer.
  ///
  /// Mirrors the resolved-then-pending lookup order [_handlePipelinedCall]
  /// already uses (see [AnswerTable.resolvedFor]/[AnswerTable.pendingFor]),
  /// with one extra case: failed
  /// answers are retained until Finish so a `takeFromOtherQuestion` that
  /// races with the failure still observes the original server exception
  /// rather than a misleading "unknown question id".
  Future<ResolvedAnswer> _resolveLocalAnswer(int qid) {
    final resolved = _answerTable.resolvedFor(qid);
    if (resolved != null) return Future.value(resolved);
    final pending = _answerTable.pendingFor(qid);
    if (pending != null) return pending;
    final error = _answerTable.errorFor(qid);
    if (error != null) throw error;
    throw RpcException(
      'takeFromOtherQuestion referenced unknown question id $qid',
    );
  }

  /// Ends [tracker]'s deferred-release window (a no-op, returning `true`,
  /// for a null/empty tracker — no capability params means nothing to
  /// release) and decides `Return.releaseParamCaps`: `true` when every
  /// params capability freshly imported for the call was disposed before it
  /// settled — their wire Release was already folded into the refcount
  /// decrement done by [_ImportedCapability]'s deferred sink and none needs
  /// sending — otherwise flushes an explicit Release for just the ones that
  /// were disposed and returns `false`. Either way, clears each wrapper's
  /// sink so a *later* dispose() of one that's still outstanding goes
  /// through the normal (non-deferred) [_releaseImport] path.
  bool _finalizeParamCapsTracker(_ParamCapsReleaseTracker? tracker) {
    if (tracker == null) return true;
    for (final wrapper in tracker.wrappers) {
      wrapper._deferredReleaseSink = null;
    }
    if (tracker.disposedImportIds.length == tracker.wrappers.length) {
      return true;
    }
    for (final id in tracker.disposedImportIds) {
      _sendRaw(buildReleaseMessage(id, 1));
    }
    return false;
  }

  /// Handles a [Capability.tryTailCall] result for the call answered by
  /// [qid]. When [tailCall]'s target is a capability imported from this
  /// same peer connection, applies the Level 1 wire optimization: forwards
  /// a new Call (flagged `sendResultsTo=yourself`) to that peer and answers
  /// [qid] immediately with `takeFromOtherQuestion`, without waiting for the
  /// forwarded call to complete. Otherwise, falls back to a transparent
  /// proxy — dispatching the tail-called method directly and answering
  /// [qid] normally, with no wire-level difference from an ordinary call.
  void _dispatchTailCall(int qid, TailCall tailCall) {
    final target = tailCall.target;
    if (target is _ImportedCapability && _ownedByThisConnection(target._conn)) {
      final (forwardQid, sent) = _sendTailForwardCall(target, tailCall);
      // Must wait for the forwarded Call to actually be on the wire before
      // answering qid with takeFromOtherQuestion — otherwise the peer could
      // see the redirect before the call it points at, and fail to
      // correlate it (see _resolveLocalAnswer).
      sent
          .then((_) {
            if (_closedError != null) return;
            _sendRaw(
              buildReturnTakeFromOtherQuestionMessage(
                answerId: qid,
                questionId: forwardQid,
              ),
            );
            // Nothing was exported directly for this answer — the real
            // result (and any capabilities in it) live under forwardQid's
            // own answer bookkeeping, released independently when the peer
            // finishes that call. Pipelining further off qid itself is not
            // supported: a pipelined call targeting qid will fail with
            // "unknown promisedAnswer questionId", since qid's resolved/
            // pending answer state is deliberately never populated here.
            _answerTable.completeSuccessfully(qid);
          })
          .catchError((Object err) {
            if (_closedError != null) return;
            _answerTable.completeSuccessfully(qid);
            _sendRaw(
              buildReturnExceptionMessage(
                answerId: qid,
                reason: err is RpcException ? err.message : err.toString(),
              ),
            );
          });
      return;
    }
    // Not a same-connection import: no wire optimization possible, just
    // dispatch the tail-called method directly and answer qid normally.
    _runDispatch(
      qid,
      target,
      tailCall.interfaceId,
      tailCall.methodId,
      tailCall.params,
      tailCall.paramsCapabilities,
    );
  }

  /// Sends a forwarded Call (flagged `sendResultsTo=yourself`) to [target]'s
  /// peer, as part of applying the tail-call wire optimization in
  /// [_dispatchTailCall]. Returns `(questionId, sent)`, where [sent]
  /// completes once the Call has actually been written to the outgoing
  /// sink — callers must wait for it before answering the original call
  /// with takeFromOtherQuestion, so the peer never observes the redirect
  /// before the call it references.
  ///
  /// The forwarded call's actual outcome is irrelevant to this vat — it's
  /// delivered to whichever of this vat's own outgoing calls the peer
  /// correlates via `takeFromOtherQuestion` (see [_resolveLocalAnswer]),
  /// not to us. This just needs to send Finish once any Return arrives, so
  /// it talks to the wire directly via [OutgoingCallCoordinator.startUsing]
  /// rather than going through `start`/`_awaitReturn` (which expects a real
  /// result).
  (int, Future<void>) _sendTailForwardCall(
    _ImportedCapability target,
    TailCall tailCall,
  ) {
    final question = _questionTable.allocate();
    final qid = question.id;
    final completer = question.returnCompleter;
    final sentCompleter = question.sentCompleter!;

    // Usually a no-op rollback target: tailCall's params are almost always
    // _ImportedCapability from this same connection, which capTable
    // resolution categorizes as receiverHosted (no export created) — but a
    // receiverHosted-descriptor param on the *original* incoming call
    // resolves to this vat's own capability object (see
    // _capabilityFromDescriptor's disc-3 case), which *does* get a fresh
    // senderHosted export when forwarded here.
    _outgoingCalls.startUsing(
      question: question,
      target: ImportedCapabilityTarget(target._importIdFuture),
      params: SerializedParams(tailCall.params.bytes),
      interfaceId: tailCall.interfaceId,
      methodId: tailCall.methodId,
      paramsCapabilities: tailCall.paramsCapabilities,
      sendResultsToYourself: true,
    );

    completer!.future
        .then(
          (_) {
            _questionTable.takeParamExportIds(qid);
            _sendRaw(buildFinishMessage(qid, releaseResultCaps: false));
          },
          onError: (Object error, StackTrace stackTrace) {
            _questionTable.takeParamExportIds(qid);
          },
        )
        .ignore();

    return (qid, sentCompleter.future);
  }

  /// Runs [cap]'s dispatch for [interfaceId]/[methodId] and answers [qid]
  /// once it settles. This is [_dispatchToCapability]'s original body,
  /// generalized so it also serves [_dispatchTailCall]'s fallback path and
  /// calls received with `sendResultsTo=yourself` — [sendResultsToYourself]
  /// only changes which kind of Return is sent on completion.
  void _runDispatch(
    int qid,
    Capability cap,
    int interfaceId,
    int methodId,
    RpcPayload params,
    List<Capability> paramsCapabilities, {
    bool sendResultsToYourself = false,
  }) {
    final cancellation = DispatchCancellationController();

    // Params capabilities freshly imported for this call (see
    // _dispatchToCapability/_capabilityFromDescriptor — every senderHosted/
    // senderPromise entry in the incoming Call's capTable creates a brand
    // new _ImportedCapability wrapper) get a deferred release sink for the
    // lifetime of this dispatch, so Return.releaseParamCaps can be set
    // without an extra wire Release when the callee turns out not to need
    // them past the call — see _finalizeParamCapsTracker.
    final paramImportWrappers = paramsCapabilities
        .whereType<_ImportedCapability>()
        .where((c) => _ownedByThisConnection(c._conn))
        .toList(growable: false);
    final paramCapsTracker =
        paramImportWrappers.isEmpty
            ? null
            : _ParamCapsReleaseTracker(paramImportWrappers);
    if (paramCapsTracker != null) {
      for (final wrapper in paramImportWrappers) {
        wrapper._deferredReleaseSink = (id) {
          _importTable.decrementRefcount(id, _disposeIgnoringErrors);
          paramCapsTracker.disposedImportIds.add(id);
        };
      }
    }

    final dispatchFuture = Future.sync(
      () => cap.dispatchWithContext(
        interfaceId,
        methodId,
        params,
        paramsCapabilities: paramsCapabilities,
        context: cancellation.context,
      ),
    );

    // Track the resolved-answer future so pipelined calls can queue behind it.
    // Attach .ignore() to prevent unhandled-rejection if dispatch throws —
    // pipelined callers handle the error via their own catchError.
    final resolvedFuture = dispatchFuture.then(
      (r) => ResolvedAnswer(r.payload.bytes, r.caps),
    );
    resolvedFuture.ignore();
    _answerTable.beginDispatch(qid, resolvedFuture, cancellation);

    dispatchFuture
        .then((result) {
          // The connection was torn down while this dispatch was still
          // running. _tearDown() already cleared the answer tables; don't
          // resurrect an entry for a peer that's no longer there. _sendRaw()
          // below would silently no-op anyway, but skip the bookkeeping too
          // so nothing lingers for a caller to observe as a leak. The result
          // is never sent as a Return, so any capabilities it carries would
          // otherwise never be disposed — dispose them here instead.
          if (_closedError != null) {
            _answerTable.settleDispatch(qid);
            _disposeResultCapabilities(result);
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }

          if (sendResultsToYourself) {
            // Results are consumed locally by whichever of the peer's own
            // outgoing calls receives Return.takeFromOtherQuestion=qid —
            // nothing is put on the wire for this Return.
            // The answer table is a non-owning rendezvous point in this path:
            // `_awaitReturn()` hands the same local capabilities to the
            // original caller as its DispatchResult, and the later Finish for
            // this forwarded question uses releaseResultCaps=false. Therefore
            // Finish must only drop bookkeeping here, not dispose result.caps.
            //
            // completeDispatchSuccessfully() runs *before* _sendRaw(): if it
            // ran after (like the plain _answerTable.completeSuccessfully()
            // this used to be), qid would sit briefly untracked between the
            // two calls, which a peer that reacts to this very Return
            // through a synchronously-reentrant sink (e.g. an in-memory or
            // `sync: true` transport) could observe — see that method's doc
            // comment.
            final completed = _answerTable.completeDispatchSuccessfully(
              qid,
              resolved: ResolvedAnswer(result.payload.bytes, result.caps),
            );
            if (!completed) {
              _disposeResultCapabilities(result);
              _finalizeParamCapsTracker(paramCapsTracker);
              return;
            }
            _sendRaw(buildReturnResultsSentElsewhereMessage(answerId: qid));
            // No Return field exists on this variant to carry
            // releaseParamCaps, so just flush any deferred params releases
            // as ordinary Release messages.
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }

          final resultDescriptors = <RpcCapDescriptor>[];
          for (final c in result.caps) {
            resultDescriptors.add(_capabilityProtocol.returnCapDescriptor(c));
          }
          // No capabilities anywhere in the results means no wire-level
          // pipelined call against this answer could ever resolve to
          // anything but "not a capability" — so it's safe to tell the peer
          // no Finish is needed and immediately drop the answer's
          // pipelining bookkeeping ourselves, instead of waiting for it.
          final noFinishNeeded = resultDescriptors.isEmpty;
          // Record the answer before sending — see the comment on the
          // sendResultsToYourself branch above for why the ordering matters.
          final completed = _answerTable.completeDispatchSuccessfully(
            qid,
            resolved: ResolvedAnswer(result.payload.bytes, result.caps),
            resultExportIds: [
              for (final d in resultDescriptors)
                if (d.disc == 1 || d.disc == 2) d.id,
            ],
          );
          if (!completed) {
            _disposeResultCapabilities(result);
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          final releaseParamCaps = _finalizeParamCapsTracker(paramCapsTracker);
          // getRootRaw() resolves in place for an envelope- or
          // builder-backed payload (no serialize-then-reparse round trip;
          // see RpcPayload/buildReturnResultsMessageFromReader) and only
          // falls back to parsing bytes for a genuinely bytes-backed one.
          _sendRaw(
            buildReturnResultsMessageFromReader(
              answerId: qid,
              resultsRoot: result.payload.getRootRaw(),
              descriptors: resultDescriptors,
              releaseParamCaps: releaseParamCaps,
              noFinishNeeded: noFinishNeeded,
            ),
          );
          if (noFinishNeeded) {
            // No Finish is coming for this qid (see above) — drop the
            // answer bookkeeping just recorded, exactly as if Finish had
            // already arrived for it. Recording it before send (above) and
            // only dropping it now, after, still keeps it visible for the
            // whole synchronous span the Return is actually sent in.
            _answerTable.finish(qid);
          }
        })
        .catchError((Object err) {
          if (_closedError != null) {
            _answerTable.settleDispatch(qid);
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          final rpcError =
              err is CapnpException
                  ? err
                  : RpcException(err.toString(), kind: ErrorKind.failed);
          if (sendResultsToYourself) {
            // See the matching comment in the success branch above for why
            // this runs before _sendRaw().
            final completed = _answerTable.completeDispatchWithError(
              qid,
              rpcError,
            );
            if (!completed) {
              _finalizeParamCapsTracker(paramCapsTracker);
              return;
            }
            _sendRaw(buildReturnResultsSentElsewhereMessage(answerId: qid));
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          // An exception Return never carries a results payload/capTable,
          // so — same reasoning as the noFinishNeeded branch above — no
          // Finish is ever needed for it, and no answer-lifecycle state
          // needs to be recorded for this qid at all. settleDispatch() still
          // needs to run, though, to detect a Finish that arrived early.
          if (_answerTable.settleDispatch(qid)) {
            _finalizeParamCapsTracker(paramCapsTracker);
            return;
          }
          final releaseParamCaps = _finalizeParamCapsTracker(paramCapsTracker);
          _sendRaw(
            buildReturnExceptionMessage(
              answerId: qid,
              reason: rpcError.message,
              kind: rpcError.kind,
              releaseParamCaps: releaseParamCaps,
              noFinishNeeded: true,
            ),
          );
        });
  }

  void _handleFinish(RpcMessage msg) {
    final resultExportIds = _answerTable.finish(msg.questionId);
    if (resultExportIds == null || !msg.releaseResultCaps) return;
    for (final eid in resultExportIds) {
      _exportTable.release(eid, _disposeIgnoringErrors);
    }
  }

  /// If [qid] already has tracked answer-lifecycle state (from Bootstrap or
  /// an in-flight/finished Call — see [AnswerTable.isTracked]), tears the
  /// connection down as a protocol violation and returns true. A
  /// well-behaved peer never reuses a question ID before it has fully
  /// settled (Finish sent and Return received) — if it does anyway,
  /// registering the new dispatch would silently clobber the cancellation
  /// and pending/resolved-answer state for the still-live one, corrupting
  /// cancellation and Return/Finish bookkeeping for both.
  bool _rejectDuplicateQuestionId(int qid) {
    if (!_answerTable.isTracked(qid)) return false;
    _tearDown(
      RpcException('protocol violation: duplicate incoming question ID $qid'),
    );
    return true;
  }

  /// Disposes every capability in a completed dispatch [result] that will
  /// never be sent to the peer as a Return (the connection closed, or a
  /// Finish arrived and canceled this answer before dispatch finished).
  /// Ownership of `result.caps` passes to the RPC runtime the moment the
  /// dispatch future resolves; if the result isn't going out on the wire,
  /// this is the only remaining chance to release those capabilities.
  ///
  /// These capabilities were never exported (that only happens on the send
  /// path we're skipping here), so there's no refcount to fall back on if
  /// the same capability instance appears more than once in `result.caps` —
  /// each distinct instance is disposed exactly once, by identity, rather
  /// than once per occurrence. A dispose failure on one capability doesn't
  /// stop the rest from being disposed.
  void _disposeResultCapabilities(DispatchResult result) {
    final disposed = HashSet<Capability>.identity();
    for (final cap in result.caps) {
      if (disposed.add(cap)) {
        _disposeIgnoringErrors(cap);
      }
    }
  }
}
