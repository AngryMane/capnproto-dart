/// Incoming Call routing: Bootstrap requests, promised-answer targets,
/// and resolving an incoming Call to the [Capability] it dispatches
/// against. Moved out of [TwoPartyRpcConnection] verbatim -- see that
/// class's own doc comment.

part of 'two_party_connection.dart';

extension _IncomingCallFlow on TwoPartyRpcConnection {
  void _handleBootstrap(RpcMessage msg) {
    if (_rejectDuplicateQuestionId(msg.questionId)) return;
    // Server side: send Return with our bootstrap capability (export 0).
    _sendRaw(
      buildBootstrapReturnMessage(answerId: msg.questionId, exportId: 0),
    );
    // Each Bootstrap request hands the peer a new reference to export 0,
    // exactly like ExportTable.getOrCreate does for capabilities returned
    // from ordinary calls — without this, a peer that bootstraps twice and
    // later disposes just one of the two resulting capabilities would drop
    // this side's refcount to 0 and dispose the capability out from under
    // the peer's other, still-live reference.
    // Register the bootstrap answer so pipelined calls targeting
    // {receiverAnswer: {questionId: msg.questionId, transform: []}} can
    // resolve ptr[0] → the bootstrap capability.
    final bootstrapCap = _exportTable.retainExisting(0);
    if (bootstrapCap != null) {
      _answerTable.completeSuccessfully(
        msg.questionId,
        resolved: ResolvedAnswer(TwoPartyRpcConnection._bootstrapResultBytes, [
          bootstrapCap,
        ]),
      );
    }
  }

  void _handleCall(RpcMessage msg) {
    if (msg.targetIsPromisedAnswer) {
      _handlePipelinedCall(msg);
      return;
    }

    final identity = _exportTable.identityFor(msg.targetImportId);
    if (identity == null) {
      _sendRaw(
        buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'unknown export id: ${msg.targetImportId}',
        ),
      );
      return;
    }
    _dispatchToCapability(msg, identity);
  }

  void _handlePipelinedCall(RpcMessage msg) {
    final parentQid = msg.targetPromisedAnswerQid;
    // An empty/noop-only transform is normalized to a single hop at pointer
    // slot 0. The only case where a peer legitimately sends one is a
    // promisedAnswer targeting a Bootstrap answer's capability directly —
    // Bootstrap's result has no wrapping wire struct (there's no field to
    // traverse), and this vat's own synthesized _bootstrapResultBytes
    // wrapper always places that capability at ptr slot 0 to match (see
    // _handleBootstrap). A real method's result is always a real struct, so
    // a well-behaved peer never sends an empty transform for anything else.
    final path =
        msg.targetTransformPath.isEmpty ? const [0] : msg.targetTransformPath;

    // Already resolved: dispatch immediately.
    final resolved = _answerTable.resolvedFor(parentQid);
    if (resolved != null) {
      final cap = _capFromPath(resolved, path);
      if (cap == null) {
        _sendRaw(
          buildReturnExceptionMessage(
            answerId: msg.questionId,
            reason: 'pointer path $path in result struct is not a capability',
          ),
        );
        return;
      }
      _dispatchToCapability(msg, cap);
      return;
    }

    // Still pending: queue behind the parent dispatch.
    final pending = _answerTable.pendingFor(parentQid);
    if (pending == null) {
      _sendRaw(
        buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'unknown promisedAnswer questionId: $parentQid',
        ),
      );
      return;
    }
    pending
        .then((resolved) {
          final cap = _capFromPath(resolved, path);
          if (cap == null) {
            _sendRaw(
              buildReturnExceptionMessage(
                answerId: msg.questionId,
                reason:
                    'pointer path $path in result struct is not a capability',
              ),
            );
            return;
          }
          _dispatchToCapability(msg, cap);
        })
        .catchError((Object err) {
          _sendRaw(
            buildReturnExceptionMessage(
              answerId: msg.questionId,
              reason: 'parent call failed: $err',
            ),
          );
        });
  }

  Capability? _capFromPath(ResolvedAnswer resolved, List<int> path) =>
      capabilityFromResultPath(
        DispatchResult(
          payload: RpcPayload.fromBytes(resolved.resultBytes),
          caps: resolved.caps,
        ),
        path,
      );
  void _dispatchToCapability(RpcMessage msg, Capability cap) {
    final qid = msg.questionId;
    if (_rejectDuplicateQuestionId(qid)) return;
    final paramsContent = msg.paramsContent;
    final params =
        paramsContent != null
            ? RpcPayload.fromEnvelope(paramsContent)
            : RpcPayload.fromBytes(TwoPartyRpcConnection._emptyResultBytes);

    // Resolve capabilities from the incoming capTable.
    // Each entry in the list must correspond 1-to-1 with the capTable index,
    // because capability pointers in the params struct reference these indices.
    // `none` descriptors get a NullCapability placeholder so subsequent
    // indices remain correct. Unsupported descriptors are protocol errors:
    // silently treating them as null loses information and can change the
    // meaning of an otherwise valid call.
    final paramsCapabilities = <Capability>[];
    try {
      for (final descriptor in msg.capTableDescriptors) {
        paramsCapabilities.add(_capabilityFromDescriptor(descriptor));
      }
    } catch (error) {
      // Every entry decoded successfully before whatever failed is a real,
      // live reference (an import refcount bump, a vended receiverHosted
      // handle, ...) — dispose them *before* deciding what to do with the
      // error itself, including the unimplemented/rethrow path below,
      // which tears the whole connection down: _tearDown only ever
      // disposes each export's own single `ownedReference` (see that
      // field's doc comment) — it has no way to know about an *additional*
      // handle vended into a local variable like this one, so leaving one
      // undisposed here would leak a permanent share of that identity's
      // refcount, potentially high enough that its own real capability
      // never actually gets disposed even once every other reference to it
      // (including the export's own) is long gone. A malicious peer could
      // repeat this pattern — one valid entry, then an invalid one — every
      // connection to accumulate exactly such leaked references.
      for (final capability in paramsCapabilities) {
        _disposeIgnoringErrors(capability);
      }

      // A disc this vat doesn't implement at all (e.g. thirdPartyHosted) is
      // a bigger deal than a single bad call — see the `default` case in
      // _capabilityFromDescriptor and the "tears down the connection as
      // unimplemented" test for this exact behavior — so let that kind
      // keep propagating to this listener's own outer try/catch, which
      // tears the whole connection down. Same for anything that isn't even
      // an RpcException: _capabilityFromDescriptor itself never throws
      // anything else today, but this being a peer-triggered decode loop,
      // silently downgrading an unexpected failure type to an ordinary
      // per-call Return.exception would be the wrong default.
      if (error is! RpcException || error.kind == ErrorKind.unimplemented) {
        rethrow;
      }

      // Every other decode failure here (e.g. a receiverHosted descriptor
      // naming an export id we don't have) is just this one call's
      // problem: fail only it, with a normal Return.exception, and keep
      // serving the connection.
      //
      // Registers qid as answered — with no result-capability export ids
      // to release later, since this call never reached a real dispatch —
      // so _rejectDuplicateQuestionId can still catch a peer illegally
      // reusing this same qid before sending Finish for it, exactly like
      // every other Return sent without a real dispatch throughout this
      // file (see the sibling `_answerTable.completeSuccessfully(qid)`
      // sites).
      _answerTable.completeSuccessfully(qid);

      _sendRaw(
        buildReturnExceptionMessage(
          answerId: qid,
          reason: error.message,
          // The dispose() calls above already sent a real wire Release for
          // every import successfully resolved before the failing
          // descriptor (see _ImportedCapability.dispose()) — leaving this
          // at its default (true) would additionally tell the peer it
          // doesn't need to send its own Release for those same export
          // ids, so it would apply *both*: its own remoteRefCount would be
          // decremented twice for what was really only one release,
          // potentially tearing its own capability down while some other
          // legitimate reference to it is still outstanding.
          releaseParamCaps: false,
        ),
      );
      return;
    }

    // sendResultsTo=yourself: the peer is asking us to forward this call's
    // real answer onward ourselves (tail call). We never consult
    // tryTailCall for such a call — that would mean chaining a tail call
    // off another tail call, which isn't supported (see doc/rpc.md) — just
    // dispatch normally and answer with resultsSentElsewhere instead of a
    // real Return once it settles.
    final sendResultsToYourself = msg.sendResultsToDisc == 1;
    if (!sendResultsToYourself) {
      final TailCall? tailCall;
      try {
        tailCall = cap.tryTailCall(
          msg.interfaceId,
          msg.methodId,
          params,
          paramsCapabilities: paramsCapabilities,
        );
      } catch (error) {
        _answerTable.completeSuccessfully(qid);
        _sendRaw(
          buildReturnExceptionMessage(
            answerId: qid,
            reason: error is CapnpException ? error.message : error.toString(),
            kind: error is CapnpException ? error.kind : ErrorKind.failed,
          ),
        );
        return;
      }
      if (tailCall != null) {
        _dispatchTailCall(qid, tailCall);
        return;
      }
    }

    _runDispatch(
      qid,
      cap,
      msg.interfaceId,
      msg.methodId,
      params,
      paramsCapabilities,
      sendResultsToYourself: sendResultsToYourself,
    );
  }
}
