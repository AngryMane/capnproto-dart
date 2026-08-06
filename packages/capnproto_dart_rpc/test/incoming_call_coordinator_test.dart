import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/capability/rpc_payload.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/answer_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/incoming_call_coordinator.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/outgoing_call.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/question_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/export_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/rpc_capability_reference.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_proto.dart';
import 'package:test/test.dart';

/// Pre-built 16-byte message: single segment (1 word), null root pointer —
/// same shape as `IncomingCallCoordinator`'s own `_emptyResultBytes`. Used
/// both as [buildCallMessage]'s `paramsBytes` and, for a "resolved answer"
/// fixture, as a result whose root has zero pointer words — so a transform
/// path into it never resolves to a capability (`_capFromPath` returns
/// null).
final _emptyMessageBytes = Uint8List.fromList([
  0, 0, 0, 0, 1, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, //
]);

/// 24-byte message: struct with 0 data words, 1 pointer word =
/// CapabilityPointer(index=0) — same shape as `IncomingCallCoordinator`'s
/// own `_bootstrapResultBytes`. Used as a "resolved answer" fixture whose
/// caps[0] is reachable at transform path [0].
final _singleCapResultBytes = Uint8List.fromList([
  0, 0, 0, 0, 2, 0, 0, 0, // header: 1 segment, 2 words
  0, 0, 0, 0, 0, 0, 1, 0, // struct ptr: offset=0, data=0, ptrs=1
  3, 0, 0, 0, 0, 0, 0, 0, // ptr[0] = CapabilityPointer(index=0)
]);

typedef _StartUsingCall =
    ({
      OutgoingCallTarget target,
      List<Capability> paramsCapabilities,
      bool sendResultsToYourself,
    });

class _FakeCapability extends Capability {
  var disposeCount = 0;
  final dispatches = <(int, int)>[];

  /// Settable per test. Defaults to an empty, no-capabilities success.
  DispatchResult Function(int interfaceId, int methodId, RpcPayload params)?
  onDispatch;

  /// Settable per test — thrown from [dispatch] instead of running
  /// [onDispatch], if set.
  Object? throwOnDispatch;

  /// Settable per test — defaults to never tail-calling, matching
  /// [Capability]'s own default.
  TailCall? Function(int interfaceId, int methodId, RpcPayload params)?
  onTryTailCall;

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    dispatches.add((interfaceId, methodId));
    final failure = throwOnDispatch;
    if (failure != null) throw failure;
    return onDispatch?.call(interfaceId, methodId, params) ??
        DispatchResult.empty;
  }

  @override
  TailCall? tryTailCall(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) => onTryTailCall?.call(interfaceId, methodId, params);

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

/// Builds an [IncomingCallCoordinator] with fake, observable dependencies —
/// no `TwoPartyRpcConnection`/sockets — proving the class extracted in
/// Stage 5 is genuinely testable standalone. Mirrors
/// `capability_protocol_test.dart`/`outgoing_call_coordinator_test.dart`'s
/// harness pattern: real lightweight tables, fake closures for everything
/// that would otherwise need a real connection.
class _Harness {
  final exportTable = ExportTable();
  final answerTable = AnswerTable();
  final questions = QuestionTable();
  final sentBytes = <Uint8List>[];
  final disposedFromTable = <Object>[];
  final tearDownCalls = <RpcException>[];
  final startUsingCalls = <_StartUsingCall>[];

  /// Settable per test — defaults to just recording the bytes in
  /// [sentBytes]. Tests that need to exercise reentrancy (a peer reacting
  /// to a Return through a synchronously-reentrant sink) replace this to
  /// call back into the coordinator from inside the send itself — the
  /// replacement is responsible for still recording into [sentBytes] if
  /// the test needs both.
  late void Function(Uint8List bytes) sendBytes = sentBytes.add;

  /// Settable per test — defaults to "connection never closes".
  bool Function() isClosed = () => false;

  /// Settable per test — defaults to "nothing classifies as a wire
  /// capability", matching a real connection's answer for any capability
  /// it doesn't itself construct.
  RpcCapabilityReference? Function(Capability cap)
  tryExtractCapabilityReference = (cap) => null;

  /// Settable per test — defaults to a fresh [_FakeCapability] per
  /// descriptor.
  Capability Function(RpcCapDescriptor descriptor) capabilityFromDescriptor =
      (descriptor) => _FakeCapability();

  /// Settable per test — defaults to a `none` descriptor for every result
  /// capability.
  RpcCapDescriptor Function(Capability cap) returnCapDescriptor =
      (cap) => const RpcCapDescriptor.none();

  /// Settable per test — defaults to completing [OutgoingQuestion.sentCompleter]
  /// immediately (mirrors `OutgoingCallCoordinator.startUsing`'s synchronous
  /// send fast path), recording the call in [startUsingCalls].
  void Function(OutgoingQuestion question, _StartUsingCall call) onStartUsing =
      (question, call) => question.sentCompleter?.complete();

  /// Settable per test — defaults to "nothing to track".
  Object? Function(List<Capability> paramsCapabilities) beginParamCapsRelease =
      (paramsCapabilities) => null;

  /// Settable per test — defaults to "always safe to fold into
  /// releaseParamCaps=true", matching a null/empty ticket.
  ({bool allDisposed, List<int> explicitReleaseIds}) Function(Object? ticket)
  finalizeParamCapsRelease =
      (ticket) => (allDisposed: true, explicitReleaseIds: const []);

  late final coordinator = IncomingCallCoordinator(
    exportTable: exportTable,
    answerTable: answerTable,
    questions: questions,
    sendBytes: (bytes) => sendBytes(bytes),
    disposeIgnoringErrors: disposedFromTable.add,
    isClosed: () => isClosed(),
    tearDownConnection: tearDownCalls.add,
    tryExtractCapabilityReference: (cap) => tryExtractCapabilityReference(cap),
    capabilityFromDescriptor:
        (descriptor) => capabilityFromDescriptor(descriptor),
    returnCapDescriptor: (cap) => returnCapDescriptor(cap),
    startUsing: ({
      required OutgoingQuestion question,
      required OutgoingCallTarget target,
      required OutgoingParams params,
      required int interfaceId,
      required int methodId,
      required List<Capability> paramsCapabilities,
      bool sendResultsToYourself = false,
    }) {
      final call = (
        target: target,
        paramsCapabilities: paramsCapabilities,
        sendResultsToYourself: sendResultsToYourself,
      );
      startUsingCalls.add(call);
      onStartUsing(question, call);
    },
    beginParamCapsRelease:
        (paramsCapabilities) => beginParamCapsRelease(paramsCapabilities),
    finalizeParamCapsRelease: (ticket) => finalizeParamCapsRelease(ticket),
  );
}

/// A Call message targeting an export id directly (not a promisedAnswer),
/// with no params capabilities unless [capTableDescriptors] is given.
Uint8List _buildCall({
  required int questionId,
  required int targetExportId,
  int interfaceId = 1,
  int methodId = 2,
  bool sendResultsToYourself = false,
  List<RpcCapDescriptor>? capTableDescriptors,
}) => buildCallMessage(
  questionId: questionId,
  targetImportId: targetExportId,
  interfaceId: interfaceId,
  methodId: methodId,
  paramsBytes: _emptyMessageBytes,
  capTableDescriptors: capTableDescriptors,
  sendResultsToYourself: sendResultsToYourself,
);

Uint8List _buildPipelinedCall({
  required int questionId,
  required int parentQid,
  List<int> transformPath = const [0],
  int interfaceId = 1,
  int methodId = 2,
  List<RpcCapDescriptor>? capTableDescriptors,
}) => buildCallMessage(
  questionId: questionId,
  targetPromisedAnswerQid: parentQid,
  targetTransformPath: transformPath,
  interfaceId: interfaceId,
  methodId: methodId,
  paramsBytes: _emptyMessageBytes,
  capTableDescriptors: capTableDescriptors,
);

void main() {
  group('IncomingCallCoordinator', () {
    test('handleBootstrap sends a Return carrying export id 0 and registers '
        'a resolved answer, so a pipelined call targeting it resolves '
        'immediately', () {
      final h = _Harness();
      final bootstrapCap =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      h.exportTable.registerBootstrap(bootstrapCap);

      h.coordinator.handleBootstrap(parseRpcMessage(buildBootstrapMessage(7)));

      expect(h.sentBytes, hasLength(1));
      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.type, equals(RpcMessageType.return_));
      expect(sent.capTableDescriptors.single.id, equals(0));
      expect(h.answerTable.isTracked(7), isTrue);

      // A pipelined call targeting {receiverAnswer: {questionId: 7, path: []}}
      // (empty transform, normalized to [0]) resolves against the bootstrap
      // capability immediately, with no queuing.
      h.coordinator.handleCall(
        parseRpcMessage(
          _buildPipelinedCall(
            questionId: 100,
            parentQid: 7,
            transformPath: const [],
          ),
        ),
      );
      expect(bootstrapCap.dispatches, hasLength(1));
    });

    test('handleCall with an already-resolved promisedAnswer parent '
        'dispatches immediately against the resolved path, and reports a '
        'protocol-level error for a path that is not a capability', () {
      final h = _Harness();
      final targetCap =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      h.answerTable.completeSuccessfully(
        1,
        resolved: ResolvedAnswer(_singleCapResultBytes, [targetCap]),
      );

      h.coordinator.handleCall(
        parseRpcMessage(_buildPipelinedCall(questionId: 200, parentQid: 1)),
      );
      expect(targetCap.dispatches, hasLength(1));

      // A second, already-resolved parent whose result has no pointer
      // fields at all: path [0] can never be a capability there.
      h.answerTable.completeSuccessfully(
        2,
        resolved: ResolvedAnswer(_emptyMessageBytes, const []),
      );
      h.coordinator.handleCall(
        parseRpcMessage(_buildPipelinedCall(questionId: 201, parentQid: 2)),
      );
      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.isReturnException, isTrue);
      expect(sent.answerId, equals(201));
      expect(sent.exceptionReason, contains('is not a capability'));
    });

    test('handleCall with a still-pending promisedAnswer parent queues and '
        'dispatches once the parent resolves, or reports an exception if '
        'the parent fails', () async {
      final h = _Harness();
      final targetCap =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final pending = Completer<ResolvedAnswer>();
      h.answerTable.beginDispatch(
        1,
        pending.future,
        DispatchCancellationController(),
      );

      h.coordinator.handleCall(
        parseRpcMessage(_buildPipelinedCall(questionId: 200, parentQid: 1)),
      );
      expect(targetCap.dispatches, isEmpty);

      pending.complete(ResolvedAnswer(_singleCapResultBytes, [targetCap]));
      await Future<void>.delayed(Duration.zero);
      expect(targetCap.dispatches, hasLength(1));

      final failingParent = Completer<ResolvedAnswer>();
      h.answerTable.beginDispatch(
        2,
        failingParent.future,
        DispatchCancellationController(),
      );
      h.coordinator.handleCall(
        parseRpcMessage(_buildPipelinedCall(questionId: 201, parentQid: 2)),
      );
      failingParent.completeError(const RpcException('parent broke'));
      await Future<void>.delayed(Duration.zero);

      final sent = parseRpcMessage(h.sentBytes.last);
      expect(sent.isReturnException, isTrue);
      expect(sent.answerId, equals(201));
      expect(sent.exceptionReason, contains('parent call failed'));
    });

    test('a tail call to a same-connection import forwards a Call flagged '
        'sendResultsToYourself, and answers the original call with '
        'takeFromOtherQuestion only after the forward is sent', () async {
      final h = _Harness();
      final forwardTarget = _FakeCapability();
      final originalCap =
          _FakeCapability()
            ..onTryTailCall =
                (interfaceId, methodId, params) =>
                    TailCall(forwardTarget, interfaceId, methodId, params);
      // Cached plain int, matching the realistic path (an _ImportedCapability
      // constructed via .fromState sets _cachedState synchronously).
      h.tryExtractCapabilityReference =
          (cap) =>
              identical(cap, forwardTarget)
                  ? const ImportedCapabilityReference(9)
                  : null;
      final exportId = h.exportTable.getOrCreate(originalCap);

      // Holds the forward "on the wire" open until the test explicitly lets
      // it through — proves the redirect actually waits for it, rather than
      // just happening to run after it because the default fake completes
      // sentCompleter synchronously either way.
      final sentGate = Completer<void>();
      h.onStartUsing = (question, call) {
        sentGate.future.then((_) => question.sentCompleter?.complete());
      };

      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 50, targetExportId: exportId)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(h.startUsingCalls, hasLength(1));
      expect(h.startUsingCalls.single.sendResultsToYourself, isTrue);
      expect(
        (h.startUsingCalls.single.target as ImportedCapabilityTarget).importId,
        equals(9),
      );
      // Nothing sent yet — the forward hasn't reached the wire.
      expect(h.sentBytes, isEmpty);

      sentGate.complete();
      await Future<void>.delayed(Duration.zero);

      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.isReturnTakeFromOtherQuestion, isTrue);
      expect(sent.answerId, equals(50));
      // The forwarded call got its own, different question id.
      expect(sent.takeFromOtherQuestion, isNot(equals(50)));
      expect(originalCap.dispatches, isEmpty);
      expect(forwardTarget.dispatches, isEmpty);
    });

    test('a tail call to a target that is not a same-connection import '
        'falls back to a transparent proxy dispatch, never forwarding a '
        'Call', () async {
      final h = _Harness();
      final forwardTarget =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final originalCap =
          _FakeCapability()
            ..onTryTailCall =
                (interfaceId, methodId, params) =>
                    TailCall(forwardTarget, interfaceId, methodId, params);
      // tryExtractCapabilityReference's default (NotWireCapability for everything).
      final exportId = h.exportTable.getOrCreate(originalCap);

      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 51, targetExportId: exportId)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(h.startUsingCalls, isEmpty);
      expect(originalCap.dispatches, isEmpty);
      expect(forwardTarget.dispatches, hasLength(1));
      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.isReturnResults, isTrue);
      expect(sent.answerId, equals(51));
    });

    test('a successful dispatch with no result capabilities sends '
        'Return.results with noFinishNeeded=true and drops the answer '
        'bookkeeping immediately', () async {
      final h = _Harness();
      final cap =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final exportId = h.exportTable.getOrCreate(cap);

      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 60, targetExportId: exportId)),
      );
      await Future<void>.delayed(Duration.zero);

      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.isReturnResults, isTrue);
      expect(sent.returnNoFinishNeeded, isTrue);
      expect(h.answerTable.isTracked(60), isFalse);
    });

    test('a failed dispatch sends Return.exception with the thrown reason/ '
        'kind and noFinishNeeded=true', () async {
      final h = _Harness();
      final cap =
          _FakeCapability()
            ..throwOnDispatch = const RpcException(
              'boom',
              kind: ErrorKind.overloaded,
            );
      final exportId = h.exportTable.getOrCreate(cap);

      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 61, targetExportId: exportId)),
      );
      await Future<void>.delayed(Duration.zero);

      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.isReturnException, isTrue);
      expect(sent.exceptionReason, equals('boom'));
      expect(sent.exceptionKind, equals(ErrorKind.overloaded));
      expect(sent.returnNoFinishNeeded, isTrue);
    });

    test('sendResultsToYourself=true sends Return.resultsSentElsewhere on '
        'both success and failure, never a normal results/exception Return, '
        'and never consults tryTailCall', () async {
      final h = _Harness();
      final succeedingCap = _FakeCapability();
      succeedingCap.onDispatch = (_, _, _) => DispatchResult.empty;
      succeedingCap.onTryTailCall =
          (_, _, _) => throw StateError('must not be called');
      final exportId1 = h.exportTable.getOrCreate(succeedingCap);
      h.coordinator.handleCall(
        parseRpcMessage(
          _buildCall(
            questionId: 70,
            targetExportId: exportId1,
            sendResultsToYourself: true,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final sent1 = parseRpcMessage(h.sentBytes.single);
      expect(sent1.returnDisc, equals(3)); // resultsSentElsewhere
      expect(sent1.isReturnResults, isFalse);

      final failingCap =
          _FakeCapability()..throwOnDispatch = const RpcException('boom');
      final exportId2 = h.exportTable.getOrCreate(failingCap);
      h.coordinator.handleCall(
        parseRpcMessage(
          _buildCall(
            questionId: 71,
            targetExportId: exportId2,
            sendResultsToYourself: true,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final sent2 = parseRpcMessage(h.sentBytes.last);
      expect(sent2.returnDisc, equals(3)); // resultsSentElsewhere
      expect(sent2.isReturnException, isFalse);
    });

    test('params-caps deferred release: an all-disposed ticket folds into '
        'releaseParamCaps=true with no explicit Release, a partial one sends '
        'explicit Releases and releaseParamCaps=false; a duplicate question '
        'id tears the connection down as a protocol violation', () async {
      final h = _Harness();
      h.beginParamCapsRelease = (paramsCapabilities) => 'ticket';

      h.finalizeParamCapsRelease =
          (ticket) => (allDisposed: true, explicitReleaseIds: const []);
      final cap1 =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final exportId1 = h.exportTable.getOrCreate(cap1);
      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 80, targetExportId: exportId1)),
      );
      await Future<void>.delayed(Duration.zero);
      var sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.returnReleaseParamCaps, isTrue);

      h.finalizeParamCapsRelease =
          (ticket) => (allDisposed: false, explicitReleaseIds: const [7, 8]);
      final cap2 =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final exportId2 = h.exportTable.getOrCreate(cap2);
      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 81, targetExportId: exportId2)),
      );
      await Future<void>.delayed(Duration.zero);
      sent = parseRpcMessage(h.sentBytes.last);
      expect(sent.returnReleaseParamCaps, isFalse);
      final releaseMessages =
          h.sentBytes
              .map(parseRpcMessage)
              .where((m) => m.type == RpcMessageType.release)
              .toList();
      expect(releaseMessages.map((m) => m.releaseId), unorderedEquals([7, 8]));

      // The case the (bool, List<int>) split exists for: zero disposed out
      // of N is NOT the same as N-of-N disposed, even though both report an
      // empty explicitReleaseIds list — only the latter is safe to fold
      // into releaseParamCaps=true.
      h.sentBytes.clear();
      h.finalizeParamCapsRelease =
          (ticket) => (allDisposed: false, explicitReleaseIds: const []);
      final cap3 =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final exportId3 = h.exportTable.getOrCreate(cap3);
      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 82, targetExportId: exportId3)),
      );
      await Future<void>.delayed(Duration.zero);
      sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.returnReleaseParamCaps, isFalse);
      expect(
        h.sentBytes
            .map(parseRpcMessage)
            .where((m) => m.type == RpcMessageType.release),
        isEmpty,
      );

      // Duplicate question id: handleCall is called twice with the same
      // questionId, the second reusing still-tracked answer state.
      final dupCap =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final dupExportId = h.exportTable.getOrCreate(dupCap);
      h.coordinator.handleCall(
        parseRpcMessage(
          _buildCall(questionId: 999, targetExportId: dupExportId),
        ),
      );
      h.coordinator.handleCall(
        parseRpcMessage(
          _buildCall(questionId: 999, targetExportId: dupExportId),
        ),
      );
      expect(h.tearDownCalls, hasLength(1));
    });

    test('a pending promised-answer resolving after teardown does not '
        'decode capabilities or dispatch its target', () async {
      final h = _Harness();
      final target =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      final pending = Completer<ResolvedAnswer>();
      h.answerTable.beginDispatch(
        1,
        pending.future,
        DispatchCancellationController(),
      );

      var descriptorDecodeCount = 0;
      h.capabilityFromDescriptor = (descriptor) {
        descriptorDecodeCount++;
        return _FakeCapability();
      };

      h.coordinator.handleCall(
        parseRpcMessage(
          _buildPipelinedCall(
            questionId: 2,
            parentQid: 1,
            capTableDescriptors: const [RpcCapDescriptor.senderHosted(7)],
          ),
        ),
      );

      h.isClosed = () => true;
      h.answerTable.tearDown();

      pending.complete(ResolvedAnswer(_singleCapResultBytes, [target]));
      await Future<void>.delayed(Duration.zero);

      expect(target.dispatches, isEmpty);
      expect(descriptorDecodeCount, equals(0));
      expect(h.answerTable.count, equals(0));
      expect(h.sentBytes, isEmpty);

      // Companion case: the parent dispatch fails instead of succeeding —
      // the catchError continuation must equally refuse to send once closed.
      final failingPending = Completer<ResolvedAnswer>();
      h.answerTable.beginDispatch(
        3,
        failingPending.future,
        DispatchCancellationController(),
      );
      h.coordinator.handleCall(
        parseRpcMessage(_buildPipelinedCall(questionId: 4, parentQid: 3)),
      );
      failingPending.completeError(const RpcException('parent broke'));
      await Future<void>.delayed(Duration.zero);

      expect(h.sentBytes, isEmpty);
    });

    test('handleBootstrap records answer state before sending its Return, '
        'so a Finish arriving synchronously as a reaction to that Return is '
        'not silently dropped', () {
      final h = _Harness();
      final bootstrapCap =
          _FakeCapability()..onDispatch = (_, _, _) => DispatchResult.empty;
      h.exportTable.registerBootstrap(bootstrapCap);

      h.sendBytes = (bytes) {
        h.sentBytes.add(bytes);
        final msg = parseRpcMessage(bytes);
        if (msg.type == RpcMessageType.return_) {
          // Simulates a peer reacting to the Return through a
          // synchronously-reentrant sink (an in-memory or `sync: true`
          // transport) by immediately sending Finish for it.
          h.coordinator.handleFinish(
            parseRpcMessage(buildFinishMessage(msg.answerId)),
          );
        }
      };

      h.coordinator.handleBootstrap(parseRpcMessage(buildBootstrapMessage(7)));

      // If the Return had been sent before the answer state existed, this
      // reentrant Finish would have found nothing to finish, and the
      // bootstrap answer would be stuck tracked forever.
      expect(h.answerTable.isTracked(7), isFalse);
    });

    test('a tail-call redirect records answer state before sending its '
        'takeFromOtherQuestion Return, so a Finish arriving synchronously '
        'as a reaction to it is not silently dropped', () async {
      final h = _Harness();
      final forwardTarget = _FakeCapability();
      final originalCap =
          _FakeCapability()
            ..onTryTailCall =
                (interfaceId, methodId, params) =>
                    TailCall(forwardTarget, interfaceId, methodId, params);
      h.tryExtractCapabilityReference =
          (cap) =>
              identical(cap, forwardTarget)
                  ? const ImportedCapabilityReference(9)
                  : null;
      final exportId = h.exportTable.getOrCreate(originalCap);

      h.sendBytes = (bytes) {
        h.sentBytes.add(bytes);
        final msg = parseRpcMessage(bytes);
        if (msg.isReturnTakeFromOtherQuestion) {
          h.coordinator.handleFinish(
            parseRpcMessage(buildFinishMessage(msg.answerId)),
          );
        }
      };

      h.coordinator.handleCall(
        parseRpcMessage(_buildCall(questionId: 50, targetExportId: exportId)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(h.answerTable.isTracked(50), isFalse);
    });
  });
}
