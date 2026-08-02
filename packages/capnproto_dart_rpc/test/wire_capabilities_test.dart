import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/capnproto_dart_rpc.dart';
import 'package:capnproto_dart_rpc/src/rpc/answer_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/two_party_connection.dart';
import 'package:capnproto_dart_rpc/src/rpc/wire_capability_context.dart';
import 'package:test/test.dart';

/// One recorded [WireCapabilityContext.startCall]/`startCallBuilding`/
/// `startResolvedImportCall` invocation.
class StartCallInvocation {
  final int? importId;
  final Future<int>? importIdFuture;
  final int interfaceId;
  final int methodId;
  final List<Capability> paramsCapabilities;
  final int? targetPromisedAnswerQid;
  final List<int> targetTransformPath;

  StartCallInvocation({
    this.importId,
    this.importIdFuture,
    required this.interfaceId,
    required this.methodId,
    required this.paramsCapabilities,
    this.targetPromisedAnswerQid,
    this.targetTransformPath = const [],
  });
}

/// A [WireCapabilityContext] test double: records every call it receives
/// instead of driving a real wire connection, so wire_capabilities.dart's
/// dispatch/dispose logic can be exercised without a real
/// [TwoPartyRpcConnection]/socket pair. See issue #64.
class FakeWireCapabilityContext implements WireCapabilityContext {
  final Map<int, ImportState> _importStates = {};
  final List<StartCallInvocation> startCallInvocations = [];
  final List<int> releasedImportIds = [];
  int _nextQid = 1;

  /// Result each recorded call's returned Future completes with. Defaults
  /// to an always-empty successful result.
  DispatchResult Function(StartCallInvocation invocation) resultFor =
      (_) => DispatchResult.empty;

  Future<ResolvedAnswer> Function(int questionId)? onResolveAnswer;

  void addImportState(ImportState state) {
    _importStates[state.importId] = state;
  }

  @override
  ImportState importStateFor(int importId) {
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

  (int, Future<DispatchResult>) _record(StartCallInvocation invocation) {
    startCallInvocations.add(invocation);
    final qid = _nextQid++;
    return (qid, Future.value(resultFor(invocation)));
  }

  @override
  (int, Future<DispatchResult>) startCall(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    Uint8List paramsBytes, {
    List<Capability> paramsCapabilities = const [],
    int? targetPromisedAnswerQid,
    List<int> targetTransformPath = const [],
  }) => _record(
    StartCallInvocation(
      importIdFuture: importIdFuture,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetTransformPath: targetTransformPath,
    ),
  );

  @override
  (int, Future<DispatchResult>) startCallBuilding(
    Future<int>? importIdFuture,
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) buildParams, {
    List<Capability> paramsCapabilities = const [],
    int? targetPromisedAnswerQid,
    List<int> targetTransformPath = const [],
  }) => _record(
    StartCallInvocation(
      importIdFuture: importIdFuture,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
      targetPromisedAnswerQid: targetPromisedAnswerQid,
      targetTransformPath: targetTransformPath,
    ),
  );

  @override
  (int, Future<DispatchResult>) startResolvedImportCall(
    int importId,
    int interfaceId,
    int methodId,
    void Function(AnyPointerBuilder) buildParams,
    List<Capability> paramsCapabilities,
  ) => _record(
    StartCallInvocation(
      importId: importId,
      interfaceId: interfaceId,
      methodId: methodId,
      paramsCapabilities: paramsCapabilities,
    ),
  );

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
  group('ImportedCapability (fake WireCapabilityContext)', () {
    test('dispatch() on a resolved import calls startResolvedImportCall '
        'with the state\'s importId, not startCall', () async {
      final context = FakeWireCapabilityContext();
      final state = ImportState(7);
      final cap = debugCreateImportedCapabilityFromState(context, state);

      await cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0)));

      expect(context.startCallInvocations, hasLength(1));
      final invocation = context.startCallInvocations.single;
      expect(invocation.importId, 7);
      expect(invocation.interfaceId, 1);
      expect(invocation.methodId, 2);
      // dispatch() marks the import as having received a call.
      expect(state.receivedCall, isTrue);
    });

    test(
      'dispatch() after dispose() rejects without calling the context',
      () async {
        final context = FakeWireCapabilityContext();
        final state = ImportState(7);
        final cap = debugCreateImportedCapabilityFromState(context, state);

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
        expect(context.startCallInvocations, isEmpty);
      },
    );

    test('dispatch() on an import resolved to a replacement forwards to it '
        'instead of calling the context', () async {
      final context = FakeWireCapabilityContext();
      final replacement = _RecordingCapability();
      final state = ImportState(7)..resolveCapability(replacement);
      final cap = debugCreateImportedCapabilityFromState(context, state);

      await cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0)));

      expect(replacement.dispatched, isTrue);
      expect(context.startCallInvocations, isEmpty);
    });

    test('dispatch() on an import resolved to an error rejects with that '
        'error without calling the context', () async {
      final context = FakeWireCapabilityContext();
      final boom = RpcException('boom', kind: ErrorKind.failed);
      final state = ImportState(7)..resolveError(boom);
      final cap = debugCreateImportedCapabilityFromState(context, state);

      await expectLater(
        cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))),
        throwsA(same(boom)),
      );
      expect(context.startCallInvocations, isEmpty);
    });

    test('dispose() releases the resolved importId through the context '
        'exactly once, even if dispose() is called twice', () async {
      final context = FakeWireCapabilityContext();
      final state = ImportState(7);
      final cap = debugCreateImportedCapabilityFromState(context, state);

      await cap.dispose();
      await cap.dispose();

      expect(context.releasedImportIds, [7]);
    });

    test('dispatchStreaming() sizes its FlowController from the context\'s '
        'streamWindowSize and calls startCall', () async {
      final context = FakeWireCapabilityContext()..streamWindowSize = 128;
      final state = ImportState(7);
      final cap = debugCreateImportedCapabilityFromState(context, state);

      await cap.dispatchStreaming(1, 2, RpcPayload.fromBytes(Uint8List(0)));

      expect(context.startCallInvocations, hasLength(1));
      expect(context.startCallInvocations.single.importId, isNull);
      expect(await context.startCallInvocations.single.importIdFuture, 7);
    });

    test('a not-yet-resolved import awaits its importIdFuture before '
        'calling the context', () async {
      final context = FakeWireCapabilityContext();
      final importIdCompleter = Completer<int>();
      final cap = debugCreateImportedCapability(
        context,
        importIdCompleter.future,
      );

      final dispatchFuture = cap.dispatch(
        1,
        2,
        RpcPayload.fromBytes(Uint8List(0)),
      );
      // The context isn't reachable synchronously — nothing has resolved
      // the import id yet.
      await Future<void>.delayed(Duration.zero);
      expect(context.startCallInvocations, isEmpty);

      context.addImportState(ImportState(42));
      importIdCompleter.complete(42);
      await dispatchFuture;

      expect(context.startCallInvocations.single.importId, 42);
    });
  });

  group('WirePipelinedCapability (fake WireCapabilityContext)', () {
    test('dispatch() before the parent resolves targets the parent '
        'question/transform path through startCall', () async {
      final context = FakeWireCapabilityContext();
      final parentResult = Completer<DispatchResult>();
      final cap = debugCreateWirePipelinedCapability(context, 99, const [
        0,
      ], parentResult.future);

      unawaited(cap.dispatch(1, 2, RpcPayload.fromBytes(Uint8List(0))));
      await Future<void>.delayed(Duration.zero);

      expect(context.startCallInvocations, hasLength(1));
      final invocation = context.startCallInvocations.single;
      expect(invocation.targetPromisedAnswerQid, 99);
      expect(invocation.targetTransformPath, [0]);
      expect(invocation.importIdFuture, isNull);

      parentResult.complete(DispatchResult.empty);
    });

    test(
      'dispatch() after dispose() rejects without calling the context',
      () async {
        final context = FakeWireCapabilityContext();
        final parentResult = Completer<DispatchResult>();
        final cap = debugCreateWirePipelinedCapability(context, 99, const [
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
        expect(context.startCallInvocations, isEmpty);
        parentResult.complete(DispatchResult.empty);
      },
    );
  });

  group('ReceiverAnswerCapability (fake WireCapabilityContext)', () {
    test('dispatch() surfaces the context\'s resolveAnswer() failure for an '
        'unknown questionId', () async {
      final context = FakeWireCapabilityContext();
      final cap = debugCreateReceiverAnswerCapability(context, 123, const [0]);

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
      expect(context.startCallInvocations, isEmpty);
    });
  });
}
