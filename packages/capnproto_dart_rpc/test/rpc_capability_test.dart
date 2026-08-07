import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/answer_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/outgoing_call.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/rpc_capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/rpc_capability_delegate.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/rpc_capability_reference.dart';
import 'package:capnproto_dart_rpc/src/rpc/two_party_connection.dart';
import 'package:test/test.dart';

/// One recorded [RpcCapabilityDelegate.startOutgoingCall] invocation.
class StartOutgoingCallInvocation {
  final OutgoingCallTarget target;
  final OutgoingParams params;
  final int interfaceId;
  final int methodId;
  final List<Capability> paramsCapabilities;

  StartOutgoingCallInvocation({
    required this.target,
    required this.params,
    required this.interfaceId,
    required this.methodId,
    required this.paramsCapabilities,
  });
}

/// A [RpcCapabilityDelegate] test double: records every call it receives
/// instead of driving a real wire connection, so rpc_capability.dart's
/// dispatch/dispose logic can be exercised without a real
/// [TwoPartyRpcConnection]/socket pair. See issue #64.
class FakeRpcCapabilityDelegate implements RpcCapabilityDelegate {
  final Map<int, ImportState> _importStates = {};
  final List<StartOutgoingCallInvocation> startCallInvocations = [];
  final List<int> releasedImportIds = [];
  int _nextQid = 1;

  /// Result each recorded call's returned Future completes with. Defaults
  /// to an always-empty successful result.
  DispatchResult Function(StartOutgoingCallInvocation invocation) resultFor =
      (_) => DispatchResult.empty;

  Future<ResolvedAnswer> Function(int questionId)? onResolveAnswer;

  void addImportState(ImportState state) {
    _importStates[state.importId] = state;
  }

  @override
  ImportState getOrCreateImportState(int importId) {
    final state = _importStates[importId];
    if (state == null) {
      throw RpcException('unknown import id $importId');
    }
    return state;
  }

  @override
  Future<void> releaseImport(int importId) async {
    releasedImportIds.add(importId);
  }

  @override
  StartedOutgoingCall startOutgoingCall({
    required OutgoingCallTarget target,
    required OutgoingParams params,
    required int interfaceId,
    required int methodId,
    List<Capability> paramsCapabilities = const [],
  }) {
    final invocation = StartOutgoingCallInvocation(
      target: target,
      params: params,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    );
    startCallInvocations.add(invocation);
    return StartedOutgoingCall(_nextQid++, Future.value(resultFor(invocation)));
  }

  @override
  Future<ResolvedAnswer> resolveAnswer(int questionId) {
    final handler = onResolveAnswer;
    if (handler != null) return handler(questionId);
    return Future.error(
      RpcException('invalid receiverAnswer questionId: $questionId'),
    );
  }

  @override
  int streamWindowSize = 64 * 1024;
}

/// Records whether it was dispatched/disposed, standing in for a resolved
/// import's `state.replacement` (see [ImportState.replacement]).
class _RecordingCapability extends Capability {
  bool dispatched = false;
  bool disposed = false;

  @override
  Future<DispatchResult> dispatch(
    int interfaceId,
    int methodId,
    RpcPayload params, {
    List<Capability> paramsCapabilities = const [],
  }) async {
    dispatched = true;
    return DispatchResult.empty;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('RPC capability reference extraction and peer binding', () {
    test('matches the connection-relative truth table', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final otherDelegate = FakeRpcCapabilityDelegate();

      final imported = createImportedCapabilityFromState(
        delegate,
        ImportState(7),
      );
      expect(
        tryExtractRpcCapabilityReference(delegate, imported),
        isA<ImportedCapabilityReference>().having(
          (reference) => reference.importId,
          'importId',
          7,
        ),
      );
      expect(isSameConnectionPeerCapability(delegate, imported), isTrue);
      expect(tryExtractRpcCapabilityReference(otherDelegate, imported), isNull);
      expect(isSameConnectionPeerCapability(otherDelegate, imported), isFalse);

      final parentResult = Completer<DispatchResult>();
      final pipelined = debugCreatePipelinedCapability(delegate, 99, const [
        0,
      ], parentResult.future);
      expect(
        tryExtractRpcCapabilityReference(delegate, pipelined),
        isA<PipelinedCapabilityReference>()
            .having(
              (reference) => reference.parentQuestionId,
              'parentQuestionId',
              99,
            )
            .having((reference) => reference.transformPath, 'transformPath', [
              0,
            ]),
      );
      expect(isSameConnectionPeerCapability(delegate, pipelined), isTrue);
      expect(
        tryExtractRpcCapabilityReference(otherDelegate, pipelined),
        isNull,
      );
      expect(isSameConnectionPeerCapability(otherDelegate, pipelined), isFalse);

      parentResult.complete(DispatchResult.empty);
      await Future<void>.delayed(Duration.zero);
      expect(tryExtractRpcCapabilityReference(delegate, pipelined), isNull);
      expect(isSameConnectionPeerCapability(delegate, pipelined), isTrue);

      final receiverAnswer = createReceiverAnswerCapability(
        delegate,
        123,
        const [0],
      );
      expect(
        tryExtractRpcCapabilityReference(delegate, receiverAnswer),
        isNull,
      );
      expect(isSameConnectionPeerCapability(delegate, receiverAnswer), isFalse);

      final local = _RecordingCapability();
      expect(tryExtractRpcCapabilityReference(delegate, local), isNull);
      expect(isSameConnectionPeerCapability(delegate, local), isFalse);
    });
  });

  group('ImportedCapability (fake RpcCapabilityDelegate)', () {
    test('dispatch() on a resolved import targets it with a synchronously '
        'known importId (ImportedCapabilityTarget)', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final state = ImportState(7);
      final cap = createImportedCapabilityFromState(delegate, state);

      await cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0)));

      expect(delegate.startCallInvocations, hasLength(1));
      final invocation = delegate.startCallInvocations.single;
      expect((invocation.target as ImportedCapabilityTarget).importId, 7);
      expect(invocation.interfaceId, 1);
      expect(invocation.methodId, 2);
      // dispatch() marks the import as having received a call.
      expect(state.receivedCall, isTrue);
    });

    test(
      'dispatch() after dispose() rejects without calling the delegate',
      () async {
        final delegate = FakeRpcCapabilityDelegate();
        final state = ImportState(7);
        final cap = createImportedCapabilityFromState(delegate, state);

        await cap.dispose();

        await expectLater(
          cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))),
          throwsA(
            isA<RpcException>().having(
              (e) => e.kind,
              'kind',
              ErrorKind.disconnected,
            ),
          ),
        );
        expect(delegate.startCallInvocations, isEmpty);
      },
    );

    test('dispatch() on an import resolved to a replacement forwards to it '
        'instead of calling the delegate', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final replacement = _RecordingCapability();
      final state = ImportState(7)..resolveCapability(replacement);
      final cap = createImportedCapabilityFromState(delegate, state);

      await cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0)));

      expect(replacement.dispatched, isTrue);
      expect(delegate.startCallInvocations, isEmpty);
    });

    test('dispatch() on an import resolved to an error rejects with that '
        'error without calling the delegate', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final boom = RpcException('boom', kind: ErrorKind.failed);
      final state = ImportState(7)..resolveError(boom);
      final cap = createImportedCapabilityFromState(delegate, state);

      await expectLater(
        cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))),
        throwsA(same(boom)),
      );
      expect(delegate.startCallInvocations, isEmpty);
    });

    test('dispose() releases the resolved importId through the delegate '
        'exactly once, even if dispose() is called twice', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final state = ImportState(7);
      final cap = createImportedCapabilityFromState(delegate, state);

      await cap.dispose();
      await cap.dispose();

      expect(delegate.releasedImportIds, [7]);
    });

    test('dispatchStreaming() sizes its StreamingCallFlowController from the delegate\'s '
        'streamWindowSize and calls startOutgoingCall', () async {
      final delegate = FakeRpcCapabilityDelegate()..streamWindowSize = 128;
      final state = ImportState(7);
      final cap = createImportedCapabilityFromState(delegate, state);

      await cap.dispatchStreaming(1, 2, RpcPayload.fromBytes(Uint8List(0)));

      expect(delegate.startCallInvocations, hasLength(1));
      final target =
          delegate.startCallInvocations.single.target
              as ImportedCapabilityTarget;
      expect(target.importId, 7);
    });

    test('a not-yet-resolved import awaits its importIdFuture before '
        'calling the delegate', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final importIdCompleter = Completer<int>();
      final cap = createImportedCapability(delegate, importIdCompleter.future);

      final dispatchFuture = cap.dispatch(
        1,
        2,
        RpcPayload.fromBytes(Uint8List(0)),
      );
      // The delegate isn't reachable synchronously — nothing has resolved
      // the import id yet.
      await Future<void>.delayed(Duration.zero);
      expect(delegate.startCallInvocations, isEmpty);

      delegate.addImportState(ImportState(42));
      importIdCompleter.complete(42);
      await dispatchFuture;

      final target =
          delegate.startCallInvocations.single.target
              as ImportedCapabilityTarget;
      expect(target.importId, 42);
    });
  });

  group('PipelinedCapability (fake RpcCapabilityDelegate)', () {
    test('dispatch() before the parent resolves targets the parent '
        'question/transform path (PromisedAnswerTarget)', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final parentResult = Completer<DispatchResult>();
      final cap = debugCreatePipelinedCapability(delegate, 99, const [
        0,
      ], parentResult.future);

      unawaited(cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))));
      await Future<void>.delayed(Duration.zero);

      expect(delegate.startCallInvocations, hasLength(1));
      final target =
          delegate.startCallInvocations.single.target as PromisedAnswerTarget;
      expect(target.questionId, 99);
      expect(target.transformPath, [0]);

      parentResult.complete(DispatchResult.empty);
    });

    test(
      'dispatch() after dispose() rejects without calling the delegate',
      () async {
        final delegate = FakeRpcCapabilityDelegate();
        final parentResult = Completer<DispatchResult>();
        final cap = debugCreatePipelinedCapability(delegate, 99, const [
          0,
        ], parentResult.future);

        await cap.dispose();

        await expectLater(
          cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))),
          throwsA(
            isA<RpcException>().having(
              (e) => e.kind,
              'kind',
              ErrorKind.disconnected,
            ),
          ),
        );
        expect(delegate.startCallInvocations, isEmpty);
        parentResult.complete(DispatchResult.empty);
      },
    );
  });

  group('ReceiverAnswerCapability (fake RpcCapabilityDelegate)', () {
    test('dispatch() surfaces the delegate\'s resolveAnswer() failure for an '
        'unknown questionId', () async {
      final delegate = FakeRpcCapabilityDelegate();
      final cap = createReceiverAnswerCapability(delegate, 123, const [0]);

      await expectLater(
        cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))),
        throwsA(
          isA<RpcException>().having(
            (e) => e.message,
            'message',
            contains('123'),
          ),
        ),
      );
      expect(delegate.startCallInvocations, isEmpty);
    });
  });
}
