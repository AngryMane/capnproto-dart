import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/outgoing_call_coordinator.dart';
import 'package:capnproto_dart_rpc/src/rpc/question_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_proto.dart';
import 'package:capnproto_dart_rpc/src/rpc/wire_capability_context.dart';
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

  late final coordinator = OutgoingCallCoordinator(
    questions: questions,
    imports: imports,
    sendBytes: sentBytes.add,
    resolveCapTableMaybeSync: (paramsCapabilities, {qid}) {
      final failure = failWith;
      if (failure != null) throw failure;
      return const [];
    },
    applyReleaseParamCaps: releasedExportIds.add,
    capabilityFromDescriptor: (descriptor) => _NeverDisposedCapability(),
    resolveLocalAnswer:
        (qid) => Future.error(
          const RpcException('resolveLocalAnswer not stubbed for this test'),
        ),
    onReturn: returnsSeenByHook.add,
  );
}

RpcMessage _decodedEmptyReturn(int answerId) =>
    parseRpcMessage(
      buildReturnResultsMessage(answerId: answerId, resultsBytes: _emptyMessageBytes),
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
      expect(h.releasedExportIds, equals([
        [42],
      ]));
      expect(question.sentCompleter!.future, throwsA(isA<RpcException>()));
      expect(question.returnCompleter!.future, throwsA(isA<RpcException>()));
    });

    test('handleReturn invokes onReturn before completing the generic '
        'completer, and is a no-op for an unknown answerId', () {
      final h = _Harness();
      final started = h.coordinator.start(
        target: const ImportedCapabilityTarget(5),
        params: SerializedParams(_emptyMessageBytes),
        interfaceId: 1,
        methodId: 2,
      );

      // Unknown answerId: no hook call, no crash.
      h.coordinator.handleReturn(_decodedEmptyReturn(999999));
      expect(h.returnsSeenByHook, isEmpty);

      final msg = _decodedEmptyReturn(started.questionId);
      h.coordinator.handleReturn(msg);
      expect(h.returnsSeenByHook, equals([msg]));

      // A second Return for the same (now-consumed) answerId is also a
      // no-op, not a duplicate completion.
      h.coordinator.handleReturn(_decodedEmptyReturn(started.questionId));
      expect(h.returnsSeenByHook, equals([msg]));
    });

    test('tearDown fails a pending call and rejects any subsequent start', () async {
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
    });
  });
}
