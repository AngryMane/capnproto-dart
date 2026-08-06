import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/outgoing_call_coordinator.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/outgoing_call.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/question_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_message_codec.dart';
import 'package:test/test.dart';

// A minimal, fully-encoded, valid Cap'n Proto message (1 segment, 1 word,
// null root pointer) — same shape as TwoPartyRpcConnection's own
// `_emptyResultBytes`. Used as [buildReturnResultsMessage]'s `resultsBytes`,
// which requires a real encoded message, not raw struct bytes.
final _emptyMessageBytes = Uint8List.fromList([
  0, 0, 0, 0, 1, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, //
]);

class _NeverDisposedCapability extends Capability {
  @override
  Future<void> dispose() async {}
}

/// Builds an [OutgoingCallCoordinator] with fake, observable dependencies —
/// no [TwoPartyRpcConnection]/sockets — proving the class extracted in
/// Stage 3 is genuinely testable standalone.
class _Harness {
  final questions = QuestionTable();
  final imports = ImportTable();
  final sentBytes = <Uint8List>[];
  final releasedExportIds = <List<int>>[];
  final returnsSeenByHook = <RpcMessage>[];

  /// When set, [resolveCapTableMaybeSync] throws this instead of resolving.
  Object? failWith;

  /// Number of times [resolveCapTableMaybeSync] has actually run — used to
  /// prove a torn-down coordinator bails out *before* triggering its real
  /// side effects (export creation, refcount bumps), not just before
  /// [sendBytes].
  var resolveCapTableCallCount = 0;

  /// When set, [resolveCapTableMaybeSync] doesn't resolve until this
  /// completes — used to open a window between a build's capTable
  /// resolution starting and finishing, for tests that need `tearDown()` to
  /// land inside it.
  Completer<void>? capTableGate;

  /// Recorded every time [resolveCapTableMaybeSync]'s fake reaches the
  /// point past [capTableGate] where a real resolver (e.g.
  /// `CapabilityProtocol`'s internal `_resolveCapTableAsync`) would commit
  /// a side effect with lasting state — `ExportTable.getOrCreate`, recording a
  /// param export id against the question. Standing in for that real side
  /// effect here (rather than actually wiring up an `ExportTable`) so this
  /// harness stays connection-free — see the coordinator-level test that
  /// asserts this stays empty once `tearDown()` lands during the gate wait.
  final postGateSideEffects = <int>[];

  /// Extra hook run from inside the coordinator's own `onReturn`, after the
  /// default [returnsSeenByHook] recording — lets a single test assert
  /// something about state at the exact point `onReturn` fires.
  void Function(RpcMessage)? onReturnExtra;

  late final coordinator = OutgoingCallCoordinator(
    questions: questions,
    imports: imports,
    sendBytes: sentBytes.add,
    resolveCapTableMaybeSync: (
      paramsCapabilities, {
      qid,
      required ensureActive,
    }) {
      resolveCapTableCallCount++;
      ensureActive();
      final failure = failWith;
      if (failure != null) throw failure;
      final gate = capTableGate;
      if (gate == null) return const [];
      return gate.future.then((_) {
        // Mirrors a real resolver resuming from its own internal `await`
        // (an import id, a pipelined param's parent being sent) — must
        // re-check before touching anything with lasting state, exactly
        // like _resolveCapTableAsync does at each of its own resume
        // points.
        ensureActive();
        postGateSideEffects.add(42);
        if (qid != null) questions.recordParamExportIds(qid, [42]);
        return const [RpcCapDescriptor.senderHosted(42)];
      });
    },
    applyReleaseParamCaps: releasedExportIds.add,
    capabilityFromDescriptor: (descriptor) => _NeverDisposedCapability(),
    resolveLocalAnswer:
        (qid) => Future.error(
          const RpcException('resolveLocalAnswer not stubbed for this test'),
        ),
    onReturn: (msg) {
      returnsSeenByHook.add(msg);
      onReturnExtra?.call(msg);
    },
  );
}

RpcMessage _decodedEmptyReturn(int answerId) => parseRpcMessage(
  buildReturnResultsMessage(
    answerId: answerId,
    resultsBytes: _emptyMessageBytes,
  ),
);

void main() {
  group('OutgoingCallCoordinator', () {
    test('start sends synchronously when the target import id is already '
        'known and the capTable resolves synchronously', () {
      final h = _Harness();
      final started = h.coordinator.start(
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
      );

      // No await anywhere above: if this were the async path, sendBytes
      // wouldn't have run yet.
      expect(h.sentBytes, hasLength(1));
      expect(h.questions.pendingSentCount, equals(0));
      expect(h.questions.pendingCount, equals(1));

      h.coordinator.handleReturn(_decodedEmptyReturn(started.questionId));
      expect(started.result, completes);
    });

    test('start awaits the import id future before sending when it is not '
        'yet resolved', () async {
      final h = _Harness();
      final importId = Completer<int>();
      final started = h.coordinator.start(
        target: ImportedCapabilityTarget(importId.future),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
      );

      // Nothing can have been sent yet — the target import id isn't known.
      await Future<void>.delayed(Duration.zero);
      expect(h.sentBytes, isEmpty);

      importId.complete(9);
      await Future<void>.delayed(Duration.zero);
      expect(h.sentBytes, hasLength(1));

      h.coordinator.handleReturn(_decodedEmptyReturn(started.questionId));
      await expectLater(started.result, completes);
    });

    test('startUsing rolls back via applyReleaseParamCaps and never calls '
        'sendBytes when capTable resolution fails synchronously', () {
      final h = _Harness();
      h.failWith = const RpcException('boom');
      final question = h.questions.allocate();
      h.questions.recordParamExportIds(question.id, [42]);

      h.coordinator.startUsing(
        question: question,
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
        paramsCapabilities: const [],
      );

      expect(h.sentBytes, isEmpty);
      expect(
        h.releasedExportIds,
        equals([
          [42],
        ]),
      );
      expect(question.sentCompleter!.future, throwsA(isA<RpcException>()));
      expect(question.returnCompleter!.future, throwsA(isA<RpcException>()));
    });

    test('handleReturn invokes onReturn before completing the generic '
        'completer, and is a no-op for an unknown answerId', () {
      final h = _Harness();
      // Allocated directly (rather than via start()) so the test can hold
      // the exact Completer<RpcMessage> the coordinator will complete —
      // takeReturn() nulls out OutgoingQuestion.returnCompleter the moment
      // handleReturn takes it, so this must be captured *before* that.
      final question = h.questions.allocate();
      final returnCompleter = question.returnCompleter!;
      h.coordinator.startUsing(
        question: question,
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
        paramsCapabilities: const [],
      );

      // Unknown answerId: no hook call, no crash.
      h.coordinator.handleReturn(_decodedEmptyReturn(999999));
      expect(h.returnsSeenByHook, isEmpty);

      h.onReturnExtra = (_) {
        // The whole point of routing bootstrap-Return handling through this
        // hook (see OutgoingCallCoordinator's own doc comment) is that it
        // must run before the original caller can observe a completed
        // Return — checked directly against the real Completer, not via a
        // downstream .then(), since await always defers by at least one
        // microtask even for an already-completed Future and so wouldn't
        // actually distinguish "before" from "just after, same tick".
        expect(returnCompleter.isCompleted, isFalse);
      };

      final msg = _decodedEmptyReturn(question.id);
      h.coordinator.handleReturn(msg);
      expect(h.returnsSeenByHook, equals([msg]));
      expect(returnCompleter.isCompleted, isTrue);

      // A second Return for the same (now-consumed) answerId is also a
      // no-op, not a duplicate completion.
      h.onReturnExtra = null;
      h.coordinator.handleReturn(_decodedEmptyReturn(question.id));
      expect(h.returnsSeenByHook, equals([msg]));
    });

    test(
      'tearDown fails a pending call and rejects any subsequent start',
      () async {
        final h = _Harness();
        final started = h.coordinator.start(
          target: const ImportedCapabilityTarget(5),
          params: SerializedParams(_emptyMessageBytes),
          interfaceId: 1,
          methodId: 2,
        );

        final err = const RpcException('connection torn down');
        h.coordinator.tearDown(err);
        await expectLater(started.result, throwsA(isA<RpcException>()));

        expect(
          () => h.coordinator.start(
            target: const ImportedCapabilityTarget(5),
            params: SerializedParams(_emptyMessageBytes),
            interfaceId: 1,
            methodId: 2,
          ),
          throwsA(isA<RpcException>()),
        );
        expect(h.questions.pendingCount, equals(0));
      },
    );

    test('startUsing after tearDown fails the supplied question without '
        'sending', () {
      final h = _Harness();
      h.coordinator.tearDown(const RpcException('connection torn down'));

      // Mirrors _sendTailForwardCall: allocates its own question, then
      // calls startUsing directly — never through start(), so startUsing's
      // own entry guard is the only thing that can catch this.
      final question = h.questions.allocate();
      h.coordinator.startUsing(
        question: question,
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
        paramsCapabilities: const [],
      );

      expect(h.sentBytes, isEmpty);
      expect(h.resolveCapTableCallCount, equals(0));
      expect(question.sentCompleter!.future, throwsA(isA<RpcException>()));
      expect(question.returnCompleter!.future, throwsA(isA<RpcException>()));
    });

    test('an async target resolving after tearDown does not send, or reach '
        'capTable resolution', () async {
      final h = _Harness();
      final importId = Completer<int>();
      final started = h.coordinator.start(
        target: ImportedCapabilityTarget(importId.future),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
      );

      h.coordinator.tearDown(const RpcException('connection torn down'));
      await expectLater(started.result, throwsA(isA<RpcException>()));

      // The build was still waiting on the target import id when tearDown
      // ran. Resolving it now must not resurrect the send.
      importId.complete(9);
      await Future<void>.delayed(Duration.zero);

      expect(h.sentBytes, isEmpty);
      expect(h.resolveCapTableCallCount, equals(0));
    });

    test('a build whose capTable resolution is still pending when tearDown '
        'runs does not send once it finishes', () async {
      final h = _Harness();
      final gate = Completer<void>();
      h.capTableGate = gate;

      // A synchronously-known target skips the target-await branch
      // entirely (see _buildOutgoingCallBytes's sync fast path), so the
      // only reason this build is still async is the gated capTable
      // resolution — isolating the success-callback guard from the
      // target-await guard the previous test already covers.
      final question = h.questions.allocate();
      // Mirrors start()'s own defensive ignore() for the sent completer —
      // startUsing() is called directly here (like _sendTailForwardCall
      // does), so nothing else ever attaches to it, and tearDown() below
      // completes it with an error unconditionally (unlike the return
      // completer, QuestionTable.tearDown doesn't ignore() this one itself,
      // since every real caller already has by this point).
      question.sentCompleter!.future.ignore();
      h.coordinator.startUsing(
        question: question,
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
        paramsCapabilities: const [],
      );

      await Future<void>.delayed(Duration.zero);
      expect(h.sentBytes, isEmpty);

      h.coordinator.tearDown(const RpcException('connection torn down'));

      gate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(h.sentBytes, isEmpty);
    });

    test('resolveCapTableMaybeSync side effects that would resume after '
        'tearDown during the gate wait never run, and are never recorded '
        'against the question', () async {
      // Reproduces the gap a real resolver has: resolveCapTableMaybeSync
      // isn't a pure function — a real implementation
      // (_resolveCapTableAsync) creates exports and records their ids
      // against qid as a side effect. _failIfTornDown alone can't roll
      // that back if it happens *after* tearDown() has already dropped
      // qid's QuestionTable tracking — so the fake resolver here must
      // itself refuse to proceed past the gate once torn down, via
      // ensureActive(), the same way the real one does.
      final h = _Harness();
      final gate = Completer<void>();
      h.capTableGate = gate;

      final question = h.questions.allocate();
      question.sentCompleter!.future.ignore();
      h.coordinator.startUsing(
        question: question,
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
        paramsCapabilities: const [],
      );

      await Future<void>.delayed(Duration.zero);
      expect(h.postGateSideEffects, isEmpty);

      h.coordinator.tearDown(const RpcException('connection torn down'));

      // The gate resolving now mirrors an unresolved import id/pipelined
      // parent finally settling after tearDown already ran.
      gate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(h.postGateSideEffects, isEmpty);
      expect(h.sentBytes, isEmpty);
      expect(h.releasedExportIds, isEmpty);
      // Nothing was ever recorded against qid for _failIfTornDown to roll
      // back in the first place — QuestionTable itself has no tracking
      // left for this qid at all.
      expect(h.questions.takeParamExportIds(question.id), isNull);
    });

    test('resolveCapTableMaybeSync side effects past the gate still run '
        'normally, and still send, when tearDown never happens', () async {
      // Companion to the test above: proves ensureActive() only blocks the
      // torn-down case, not every gated resolution.
      final h = _Harness();
      final gate = Completer<void>();
      h.capTableGate = gate;

      final started = h.coordinator.start(
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
      );

      await Future<void>.delayed(Duration.zero);
      expect(h.postGateSideEffects, isEmpty);
      expect(h.sentBytes, isEmpty);

      gate.complete();
      await Future<void>.delayed(Duration.zero);

      expect(h.postGateSideEffects, equals([42]));
      expect(h.sentBytes, hasLength(1));

      h.coordinator.handleReturn(_decodedEmptyReturn(started.questionId));
      await expectLater(started.result, completes);
    });
  });
}
