import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';

import '../../capability/capability.dart';
import '../../capability/rpc_payload.dart';
import '../capabilities/export_table.dart';
import '../capabilities/rpc_capability_reference.dart';
import '../rpc_exception.dart';
import '../rpc_proto.dart';
import 'answer_table.dart';
import 'outgoing_call.dart';
import 'question_table.dart';

// 24-byte message: struct with 0 data words, 1 pointer word = CapabilityPointer(0).
// Used as the synthesised result for Bootstrap answers so that pipelined
// calls targeting {receiverAnswer: {questionId: <boot>, transform: []}}
// can resolve ptr[0] → the resolved answer's caps[0] (see
// AnswerTable.resolvedFor).
// hi = (dataWords & 0xFFFF) | (ptrWords << 16)
// For dataWords=0, ptrWords=1: hi = 0x00010000 → LE bytes [0,0,1,0]
final _bootstrapResultBytes = Uint8List.fromList([
  0, 0, 0, 0, 2, 0, 0, 0, // header: 1 segment, 2 words
  0, 0, 0, 0, 0, 0, 1, 0, // struct ptr: offset=0, data=0, ptrs=1
  3, 0, 0, 0, 0, 0, 0, 0, // ptr[0] = CapabilityPointer(index=0)
]);

/// Pre-built 16-byte message: single segment (1 word), null root pointer.
/// Used as fallback for `-> stream` and void methods that return no
/// content. Connection-independent, so it's duplicated here rather than
/// injected — see `OutgoingCallCoordinator`'s own identical constant, used
/// for the same reason on the outgoing side.
final _emptyResultBytes = Uint8List.fromList([
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
]);

/// Incoming Call handling: Bootstrap requests, promised-answer targets,
/// resolving an incoming Call to the [Capability] it dispatches against,
/// running that dispatch (with cancellation and tail-call support), and
/// building/sending its Return. Extracted from `TwoPartyRpcConnection` as a
/// standalone, constructor-injected class — like `OutgoingCallCoordinator`/
/// `CapabilityProtocol`, a plain top-level class (not a `part`-file
/// extension) so it can be constructed and tested directly, without a real
/// connection or sockets.
///
/// Reaches `CapabilityProtocol` and `OutgoingCallCoordinator` through
/// narrow closures rather than holding either object directly: both are
/// declared `final class`, so a test file in a different library can't
/// fake either by implementing it — narrow closures keep this class's own
/// test harness as lightweight as its two siblings'. [startUsing] closes
/// the one genuine circular dependency in this refactor:
/// `_sendTailForwardCall` needs `OutgoingCallCoordinator.startUsing`, while
/// `OutgoingCallCoordinator`'s own `resolveLocalAnswer` field needs
/// [resolveLocalAnswer] — see the wiring site
/// (`two_party_connection.dart`) for how both directions are kept
/// deferred (closures, not eager reads) so neither side's construction
/// depends on the other's having already finished.
///
/// [beginParamCapsRelease]/[finalizeParamCapsRelease] bridge a different
/// kind of wall than [tryExtractCapabilityReference]/[capabilityFromDescriptor]/
/// [returnCapDescriptor]: those three only need to *classify* or
/// *construct* a capability, which [RpcCapabilityReference] already expresses
/// without naming `_ImportedCapability` (private to
/// `rpc_capability.dart`'s library); params-caps deferred-release
/// tracking needs to *mutate* private state
/// (`_ImportedCapability._deferredReleaseSink`) and read accumulated
/// results back later, so it's threaded through as an opaque `Object?`
/// ticket this class never inspects — see [beginParamCapsRelease]'s doc
/// comment.
final class IncomingCallCoordinator {
  /// Shared with the owning connection — also read directly by
  /// `CapabilityProtocol`/`OutgoingCallCoordinator`, so this class does not
  /// own it exclusively.
  final ExportTable exportTable;

  /// Shared with the owning connection, same reasoning as [exportTable].
  final AnswerTable answerTable;

  /// Shared with the owning connection, same reasoning as [exportTable].
  final QuestionTable questions;

  final void Function(Uint8List bytes) sendBytes;
  final void Function(Capability) disposeIgnoringErrors;

  /// Whether the owning connection has already torn down — checked in
  /// [_dispatchTailCall]/[_runDispatch]'s async continuations, which may
  /// run after teardown has already cleared the answer tables they'd
  /// otherwise touch.
  final bool Function() isClosed;

  /// Tears the whole connection down — called only from
  /// [_rejectDuplicateQuestionId] on a detected protocol violation.
  final void Function(RpcException error) tearDownConnection;

  /// Classifies a capability as wire-hosted or not — see
  /// [RpcCapabilityReference]'s doc comment. The same closure instance
  /// `CapabilityProtocol` itself uses (its `tryExtractCapabilityReference` field is
  /// public precisely so it can be shared here rather than duplicated).
  final RpcCapabilityReference? Function(Capability cap)
  tryExtractCapabilityReference;

  final Capability Function(RpcCapDescriptor descriptor)
  capabilityFromDescriptor;
  final RpcCapDescriptor Function(Capability cap) returnCapDescriptor;

  /// `OutgoingCallCoordinator.startUsing` — see this class's own doc
  /// comment for why this closure, not a direct reference to that
  /// coordinator, is what closes the circular dependency between them.
  final void Function({
    required OutgoingQuestion question,
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    required List<Capability> paramsCapabilities,
    bool sendResultsToYourself,
  })
  startUsing;

  /// Starts a deferred-release tracking window for whichever of a call's
  /// params capabilities are same-connection imports freshly created for
  /// it, returning an opaque ticket (`null` if there's nothing to track)
  /// to pass back to [finalizeParamCapsRelease] once the call settles —
  /// see [_runDispatch]'s own doc comment for why this tracking exists.
  /// Opaque because setting it up means writing a deferred-release sink
  /// onto each `_ImportedCapability` wrapper, private to
  /// `rpc_capability.dart`'s library.
  final Object? Function(List<Capability> paramsCapabilities)
  beginParamCapsRelease;

  /// Ends the tracking window [beginParamCapsRelease] started (a no-op,
  /// reporting `allDisposed` true, for a null ticket) and reports two
  /// independent things: `allDisposed` decides `Return.releaseParamCaps`
  /// directly; `explicitReleaseIds` is exactly the import ids that were
  /// disposed but still need their own wire Release sent — only ever
  /// non-empty when `allDisposed` is false, and can legitimately be
  /// *empty even when `allDisposed` is false* (nothing disposed yet at
  /// all). A genuinely named record (curly-brace syntax) — not just a
  /// positional one with names in the type signature, which wouldn't
  /// actually create `.allDisposed`/`.explicitReleaseIds` getters — so the
  /// two can't be collapsed into one ambiguous empty list at the call site
  /// (see [_finalizeParamCapsTracker], this class's own wrapper around this
  /// closure that does the actual sending).
  final ({bool allDisposed, List<int> explicitReleaseIds}) Function(
    Object? ticket,
  )
  finalizeParamCapsRelease;

  IncomingCallCoordinator({
    required this.exportTable,
    required this.answerTable,
    required this.questions,
    required this.sendBytes,
    required this.disposeIgnoringErrors,
    required this.isClosed,
    required this.tearDownConnection,
    required this.tryExtractCapabilityReference,
    required this.capabilityFromDescriptor,
    required this.returnCapDescriptor,
    required this.startUsing,
    required this.beginParamCapsRelease,
    required this.finalizeParamCapsRelease,
  });

  void handleBootstrap(RpcMessage msg) {
    if (_rejectDuplicateQuestionId(msg.questionId)) return;
    // Each Bootstrap request hands the peer a new reference to export 0,
    // exactly like ExportTable.getOrCreate does for capabilities returned
    // from ordinary calls — without this, a peer that bootstraps twice and
    // later disposes just one of the two resulting capabilities would drop
    // this side's refcount to 0 and dispose the capability out from under
    // the peer's other, still-live reference.
    // Register the bootstrap answer so pipelined calls targeting
    // {receiverAnswer: {questionId: msg.questionId, transform: []}} can
    // resolve ptr[0] → the bootstrap capability.
    //
    // Recorded *before* sending the Return — a peer that reacts to the
    // Return through a synchronously-reentrant sink (an in-memory or
    // `sync: true` transport) could otherwise observe a pipelined call
    // targeting this answer, a Finish for it, or a Release for export 0,
    // before this bookkeeping exists (see _runDispatch's own matching
    // comment for why the same ordering matters there).
    final bootstrapCap = exportTable.retainExisting(0);
    if (bootstrapCap != null) {
      answerTable.completeSuccessfully(
        msg.questionId,
        resolved: ResolvedAnswer(_bootstrapResultBytes, [bootstrapCap]),
      );
    }
    // Server side: send Return with our bootstrap capability (export 0).
    sendBytes(
      buildBootstrapReturnMessage(answerId: msg.questionId, exportId: 0),
    );
  }

  void handleCall(RpcMessage msg) {
    if (msg.targetIsPromisedAnswer) {
      _handlePipelinedCall(msg);
      return;
    }

    final identity = exportTable.identityFor(msg.targetImportId);
    if (identity == null) {
      sendBytes(
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
    // handleBootstrap). A real method's result is always a real struct, so
    // a well-behaved peer never sends an empty transform for anything else.
    final path =
        msg.targetTransformPath.isEmpty ? const [0] : msg.targetTransformPath;

    // Already resolved: dispatch immediately.
    final resolved = answerTable.resolvedFor(parentQid);
    if (resolved != null) {
      final cap = _capFromPath(resolved, path);
      if (cap == null) {
        sendBytes(
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
    final pending = answerTable.pendingFor(parentQid);
    if (pending == null) {
      sendBytes(
        buildReturnExceptionMessage(
          answerId: msg.questionId,
          reason: 'unknown promisedAnswer questionId: $parentQid',
        ),
      );
      return;
    }
    pending
        .then((resolved) {
          // The connection may have torn down while this call sat queued
          // behind the parent dispatch — tearDownConnection already cleared
          // the tables _dispatchToCapability would otherwise touch (decode
          // capTable descriptors, bump import refcounts, dispatch to the
          // application capability), and sendBytes() below would silently
          // no-op anyway, so there's nothing left to do for a peer that's
          // no longer there.
          if (isClosed()) return;
          final cap = _capFromPath(resolved, path);
          if (cap == null) {
            sendBytes(
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
          if (isClosed()) return;
          sendBytes(
            buildReturnExceptionMessage(
              answerId: msg.questionId,
              reason: 'parent call failed: $err',
            ),
          );
        })
        .ignore();
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
            : RpcPayload.fromBytes(_emptyResultBytes);

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
        paramsCapabilities.add(capabilityFromDescriptor(descriptor));
      }
    } catch (error) {
      // Every entry decoded successfully before whatever failed is a real,
      // live reference (an import refcount bump, a vended receiverHosted
      // handle, ...) — dispose them *before* deciding what to do with the
      // error itself, including the unimplemented/rethrow path below,
      // which tears the whole connection down: tearDownConnection only
      // ever disposes each export's own single `ownedReference` (see that
      // field's doc comment) — it has no way to know about an *additional*
      // handle vended into a local variable like this one, so leaving one
      // undisposed here would leak a permanent share of that identity's
      // refcount, potentially high enough that its own real capability
      // never actually gets disposed even once every other reference to it
      // (including the export's own) is long gone. A malicious peer could
      // repeat this pattern — one valid entry, then an invalid one — every
      // connection to accumulate exactly such leaked references.
      for (final capability in paramsCapabilities) {
        disposeIgnoringErrors(capability);
      }

      // A disc this vat doesn't implement at all (e.g. thirdPartyHosted) is
      // a bigger deal than a single bad call — see the `default` case in
      // CapabilityProtocol.capabilityFromDescriptor and the "tears down the
      // connection as unimplemented" test for this exact behavior — so let
      // that kind keep propagating to this listener's own outer try/catch,
      // which tears the whole connection down. Same for anything that
      // isn't even an RpcException: capabilityFromDescriptor itself never
      // throws anything else today, but this being a peer-triggered decode
      // loop, silently downgrading an unexpected failure type to an
      // ordinary per-call Return.exception would be the wrong default.
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
      // file (see the sibling `answerTable.completeSuccessfully(qid)`
      // sites).
      answerTable.completeSuccessfully(qid);

      sendBytes(
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
        answerTable.completeSuccessfully(qid);
        sendBytes(
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

  /// Handles a [Capability.tryTailCall] result for the call answered by
  /// [qid]. When [tailCall]'s target classifies (via [tryExtractCapabilityReference])
  /// as a capability imported from this same peer connection, applies the
  /// Level 1 wire optimization: forwards a new Call (flagged
  /// `sendResultsTo=yourself`) to that peer and answers [qid] immediately
  /// with `takeFromOtherQuestion`, without waiting for the forwarded call
  /// to complete. Otherwise, falls back to a transparent proxy —
  /// dispatching the tail-called method directly and answering [qid]
  /// normally, with no wire-level difference from an ordinary call.
  void _dispatchTailCall(int qid, TailCall tailCall) {
    final target = tailCall.target;
    final reference = tryExtractCapabilityReference(target);
    if (reference is ImportedCapabilityReference) {
      final (forwardQid, sent) = _sendTailForwardCall(
        reference.importId,
        tailCall,
      );
      // Must wait for the forwarded Call to actually be on the wire before
      // answering qid with takeFromOtherQuestion — otherwise the peer could
      // see the redirect before the call it points at, and fail to
      // correlate it (see resolveLocalAnswer).
      sent
          .then((_) {
            if (isClosed()) return;
            // Nothing was exported directly for this answer — the real
            // result (and any capabilities in it) live under forwardQid's
            // own answer bookkeeping, released independently when the peer
            // finishes that call. Pipelining further off qid itself is not
            // supported: a pipelined call targeting qid will fail with
            // "unknown promisedAnswer questionId", since qid's resolved/
            // pending answer state is deliberately never populated here.
            //
            // Recorded *before* sending the Return — same reentrancy
            // reasoning as _runDispatch/handleBootstrap: a peer reacting to
            // this Return through a synchronously-reentrant sink could
            // otherwise send a Finish for qid before this bookkeeping
            // exists, which would then be silently dropped as a no-op
            // instead of ever clearing it.
            answerTable.completeSuccessfully(qid);
            sendBytes(
              buildReturnTakeFromOtherQuestionMessage(
                answerId: qid,
                questionId: forwardQid,
              ),
            );
          })
          .catchError((Object err) {
            if (isClosed()) return;
            answerTable.completeSuccessfully(qid);
            sendBytes(
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

  /// Sends a forwarded Call (flagged `sendResultsTo=yourself`) to
  /// [targetImportId]'s peer, as part of applying the tail-call wire
  /// optimization in [_dispatchTailCall]. Returns `(questionId, sent)`,
  /// where [sent] completes once the Call has actually been written to the
  /// outgoing sink — callers must wait for it before answering the original
  /// call with takeFromOtherQuestion, so the peer never observes the
  /// redirect before the call it references.
  ///
  /// The forwarded call's actual outcome is irrelevant to this vat — it's
  /// delivered to whichever of this vat's own outgoing calls the peer
  /// correlates via `takeFromOtherQuestion` (see [resolveLocalAnswer]), not
  /// to us. This just needs to send Finish once any Return arrives, so it
  /// talks to the wire directly via [startUsing] rather than going through
  /// `OutgoingCallCoordinator.start`/its internal `_awaitReturn` (which
  /// expects a real result).
  (int, Future<void>) _sendTailForwardCall(
    FutureOr<int> targetImportId,
    TailCall tailCall,
  ) {
    final question = questions.allocate();
    final qid = question.id;
    final completer = question.returnCompleter;
    final sentCompleter = question.sentCompleter!;

    // Usually a no-op rollback target: tailCall's params are almost always
    // _ImportedCapability from this same connection, which capTable
    // resolution categorizes as receiverHosted (no export created) — but a
    // receiverHosted-descriptor param on the *original* incoming call
    // resolves to this vat's own capability object (see
    // CapabilityProtocol.capabilityFromDescriptor's disc-3 case), which
    // *does* get a fresh senderHosted export when forwarded here.
    startUsing(
      question: question,
      target: ImportedCapabilityTarget(targetImportId),
      params: SerializedParams(tailCall.params.bytes),
      interfaceId: tailCall.interfaceId,
      methodId: tailCall.methodId,
      paramsCapabilities: tailCall.paramsCapabilities,
      sendResultsToYourself: true,
    );

    completer!.future
        .then(
          (_) {
            questions.takeParamExportIds(qid);
            if (isClosed()) return;
            sendBytes(buildFinishMessage(qid, releaseResultCaps: false));
          },
          onError: (Object error, StackTrace stackTrace) {
            questions.takeParamExportIds(qid);
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
    // _dispatchToCapability/CapabilityProtocol.capabilityFromDescriptor —
    // every senderHosted/senderPromise entry in the incoming Call's
    // capTable creates a brand new _ImportedCapability wrapper) get a
    // deferred release sink for the lifetime of this dispatch, so
    // Return.releaseParamCaps can be set without an extra wire Release
    // when the callee turns out not to need them past the call — see
    // _finalizeParamCapsTracker.
    final paramCapsTicket = beginParamCapsRelease(paramsCapabilities);

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
    answerTable.beginDispatch(qid, resolvedFuture, cancellation);

    dispatchFuture
        .then((result) {
          // The connection was torn down while this dispatch was still
          // running. tearDownConnection already cleared the answer
          // tables; don't resurrect an entry for a peer that's no longer
          // there. sendBytes() below would silently no-op anyway, but skip
          // the bookkeeping too so nothing lingers for a caller to observe
          // as a leak. The result is never sent as a Return, so any
          // capabilities it carries would otherwise never be disposed —
          // dispose them here instead.
          if (isClosed()) {
            answerTable.settleDispatch(qid);
            _disposeResultCapabilities(result);
            _finalizeParamCapsTracker(paramCapsTicket);
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
            // completeDispatchSuccessfully() runs *before* sendBytes(): if it
            // ran after (like the plain answerTable.completeSuccessfully()
            // this used to be), qid would sit briefly untracked between the
            // two calls, which a peer that reacts to this very Return
            // through a synchronously-reentrant sink (e.g. an in-memory or
            // `sync: true` transport) could observe — see that method's doc
            // comment.
            final completed = answerTable.completeDispatchSuccessfully(
              qid,
              resolved: ResolvedAnswer(result.payload.bytes, result.caps),
            );
            if (!completed) {
              _disposeResultCapabilities(result);
              _finalizeParamCapsTracker(paramCapsTicket);
              return;
            }
            sendBytes(buildReturnResultsSentElsewhereMessage(answerId: qid));
            // No Return field exists on this variant to carry
            // releaseParamCaps, so just flush any deferred params releases
            // as ordinary Release messages.
            _finalizeParamCapsTracker(paramCapsTicket);
            return;
          }

          final resultDescriptors = <RpcCapDescriptor>[];
          for (final c in result.caps) {
            resultDescriptors.add(returnCapDescriptor(c));
          }
          // No capabilities anywhere in the results means no wire-level
          // pipelined call against this answer could ever resolve to
          // anything but "not a capability" — so it's safe to tell the peer
          // no Finish is needed and immediately drop the answer's
          // pipelining bookkeeping ourselves, instead of waiting for it.
          final noFinishNeeded = resultDescriptors.isEmpty;
          // Record the answer before sending — see the comment on the
          // sendResultsToYourself branch above for why the ordering matters.
          final completed = answerTable.completeDispatchSuccessfully(
            qid,
            resolved: ResolvedAnswer(result.payload.bytes, result.caps),
            resultExportIds: [
              for (final d in resultDescriptors)
                if (d.disc == 1 || d.disc == 2) d.id,
            ],
          );
          if (!completed) {
            _disposeResultCapabilities(result);
            _finalizeParamCapsTracker(paramCapsTicket);
            return;
          }
          final releaseParamCaps = _finalizeParamCapsTracker(paramCapsTicket);
          // getRootRaw() resolves in place for an envelope- or
          // builder-backed payload (no serialize-then-reparse round trip;
          // see RpcPayload/buildReturnResultsMessageFromReader) and only
          // falls back to parsing bytes for a genuinely bytes-backed one.
          sendBytes(
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
            answerTable.finish(qid);
          }
        })
        .catchError((Object err) {
          if (isClosed()) {
            answerTable.settleDispatch(qid);
            _finalizeParamCapsTracker(paramCapsTicket);
            return;
          }
          final rpcError =
              err is CapnpException
                  ? err
                  : RpcException(err.toString(), kind: ErrorKind.failed);
          if (sendResultsToYourself) {
            // See the matching comment in the success branch above for why
            // this runs before sendBytes().
            final completed = answerTable.completeDispatchWithError(
              qid,
              rpcError,
            );
            if (!completed) {
              _finalizeParamCapsTracker(paramCapsTicket);
              return;
            }
            sendBytes(buildReturnResultsSentElsewhereMessage(answerId: qid));
            _finalizeParamCapsTracker(paramCapsTicket);
            return;
          }
          // An exception Return never carries a results payload/capTable,
          // so — same reasoning as the noFinishNeeded branch above — no
          // Finish is ever needed for it, and no answer-lifecycle state
          // needs to be recorded for this qid at all. settleDispatch() still
          // needs to run, though, to detect a Finish that arrived early.
          if (answerTable.settleDispatch(qid)) {
            _finalizeParamCapsTracker(paramCapsTicket);
            return;
          }
          final releaseParamCaps = _finalizeParamCapsTracker(paramCapsTicket);
          sendBytes(
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

  void handleFinish(RpcMessage msg) {
    final resultExportIds = answerTable.finish(msg.questionId);
    if (resultExportIds == null || !msg.releaseResultCaps) return;
    for (final eid in resultExportIds) {
      exportTable.release(eid, disposeIgnoringErrors);
    }
  }

  /// Resolves [qid] against this vat's own incoming-answer bookkeeping, for
  /// correlating a `Return.takeFromOtherQuestion` from the peer — the
  /// closure `OutgoingCallCoordinator`'s own `resolveLocalAnswer` field is
  /// wired to (see the wiring site).
  ///
  /// Mirrors the resolved-then-pending lookup order [_handlePipelinedCall]
  /// already uses (see [AnswerTable.resolvedFor]/[AnswerTable.pendingFor]),
  /// with one extra case: failed answers are retained until Finish so a
  /// `takeFromOtherQuestion` that races with the failure still observes
  /// the original server exception rather than a misleading "unknown
  /// question id".
  Future<ResolvedAnswer> resolveLocalAnswer(int qid) {
    final resolved = answerTable.resolvedFor(qid);
    if (resolved != null) return Future.value(resolved);
    final pending = answerTable.pendingFor(qid);
    if (pending != null) return pending;
    final error = answerTable.errorFor(qid);
    if (error != null) throw error;
    throw RpcException(
      'takeFromOtherQuestion referenced unknown question id $qid',
    );
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
    if (!answerTable.isTracked(qid)) return false;
    tearDownConnection(
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
        disposeIgnoringErrors(cap);
      }
    }
  }

  /// Thin wrapper around [finalizeParamCapsRelease] that also sends the
  /// wire Release for any import ids it reports needing one, and forwards
  /// `allDisposed` as `Return.releaseParamCaps` — see
  /// [finalizeParamCapsRelease]'s own doc comment for the actual decision
  /// logic.
  bool _finalizeParamCapsTracker(Object? ticket) {
    final (:allDisposed, :explicitReleaseIds) = finalizeParamCapsRelease(
      ticket,
    );
    // sendBytes() would silently no-op post-teardown anyway (a real
    // connection's own send path already does), but this coordinator
    // shouldn't rely on that — skip the send outright rather than depend on
    // a caller's hidden no-op behavior.
    if (!isClosed()) {
      for (final id in explicitReleaseIds) {
        sendBytes(buildReleaseMessage(id, 1));
      }
    }
    return allDisposed;
  }
}
