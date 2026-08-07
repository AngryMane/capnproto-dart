import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/question_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/capability_protocol.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/embargo_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/export_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/rpc_capability_reference.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_message_codec.dart';
import 'package:test/test.dart';

class _FakeCapability extends Capability {
  var disposeCount = 0;
  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

/// Builds a [CapabilityProtocol] with fake, observable dependencies — no
/// `TwoPartyRpcConnection`/sockets — proving the class extracted in Stage 4
/// is genuinely testable standalone. `tryExtractCapabilityReference`
/// returns `null` for every capability by default (i.e. no reusable RPC
/// reference),
/// which is what a real connection would also report for any capability
/// it doesn't itself wrap.
class _Harness {
  final exportTable = ExportTable();
  final importTable = ImportTable();
  final embargoTable = EmbargoTable();
  final questions = QuestionTable();
  final sentBytes = <Uint8List>[];
  final disposedFromTable = <Object>[];
  final tearDownCalls = <RpcException>[];
  final receiverAnswerCalls = <(int, List<int>)>[];

  /// Settable per test — defaults to "connection never closes".
  bool Function() isClosed = () => false;

  /// Settable per test — defaults to no reusable RPC capability reference,
  /// matching a real connection's answer for any capability it did not
  /// construct itself.
  RpcCapabilityReference? Function(Capability cap)
  tryExtractCapabilityReference = (cap) => null;

  bool Function(Capability cap) isSameConnectionPeerCapability = (cap) => false;

  late final protocol = CapabilityProtocol(
    exportTable: exportTable,
    importTable: importTable,
    embargoTable: embargoTable,
    questions: questions,
    disembargoTimeout: null,
    sendBytes: sentBytes.add,
    disposeIgnoringErrors: disposedFromTable.add,
    isClosed: () => isClosed(),
    tearDownConnection: tearDownCalls.add,
    tryExtractCapabilityReference: (cap) => tryExtractCapabilityReference(cap),
    isSameConnectionPeerCapability:
        (cap) => isSameConnectionPeerCapability(cap),
    importedCapabilityFromState: (state) => _FakeCapability(),
    receiverAnswerCapability: (qid, path) {
      receiverAnswerCalls.add((qid, path));
      return _FakeCapability();
    },
  );
}

void main() {
  group('CapabilityProtocol', () {
    test('handleRelease tears the connection down for a non-positive '
        'referenceCount, without releasing', () {
      final h = _Harness();
      final id = h.exportTable.getOrCreate(_FakeCapability());

      h.protocol.handleRelease(parseRpcMessage(buildReleaseMessage(id, 0)));

      expect(h.tearDownCalls, hasLength(1));
      expect(h.exportTable.remoteRefCountFor(id), equals(1));
    });

    test('handleRelease tears the connection down for a referenceCount '
        'exceeding the outstanding remote refcount, without releasing', () {
      final h = _Harness();
      final id = h.exportTable.getOrCreate(_FakeCapability());

      h.protocol.handleRelease(parseRpcMessage(buildReleaseMessage(id, 2)));

      expect(h.tearDownCalls, hasLength(1));
      expect(h.exportTable.remoteRefCountFor(id), equals(1));
    });

    test('handleRelease releases the reference for a valid release, and '
        'never tears the connection down', () {
      final h = _Harness();
      final id = h.exportTable.getOrCreate(_FakeCapability());

      h.protocol.handleRelease(parseRpcMessage(buildReleaseMessage(id, 1)));

      expect(h.tearDownCalls, isEmpty);
      expect(h.exportTable.remoteRefCountFor(id), isNull);
      expect(h.disposedFromTable, hasLength(1));
    });

    test('releaseImport batches two synchronous releases of the same '
        'import id into a single Release with the combined count', () async {
      final h = _Harness();
      h.importTable.retain(5);
      h.importTable.retain(5);

      final f1 = h.protocol.releaseImport(5);
      final f2 = h.protocol.releaseImport(5);
      await Future.wait([f1, f2]);

      expect(h.sentBytes, hasLength(1));
      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.type, equals(RpcMessageType.release));
      expect(sent.releaseId, equals(5));
      expect(sent.referenceCount, equals(2));
    });

    test('isClosed stops the flush loop before sending releases batched '
        'after it starts reporting closed', () async {
      final h = _Harness();
      h.importTable.retain(5);
      h.importTable.retain(6);
      unawaited(h.protocol.releaseImport(5));
      unawaited(h.protocol.releaseImport(6));

      // Allows the first pending entry's send, then reports closed — proves
      // the loop actually stops partway rather than just skipping when
      // already closed at entry.
      var checkCount = 0;
      h.isClosed = () => checkCount++ >= 1;

      await Future<void>.delayed(Duration.zero);

      expect(h.sentBytes, hasLength(1));
    });

    test('resolveParameterCapabilityDescriptors resolves synchronously when no RPC '
        'capability reference can be extracted', () {
      final h = _Harness();
      final capA = _FakeCapability();
      final capB = _FakeCapability();

      final result = h.protocol.resolveParameterCapabilityDescriptors([
        capA,
        capB,
      ], ensureActive: () {});

      expect(result, isA<List<RpcCapabilityDescriptor>>());
      final descriptors = result as List<RpcCapabilityDescriptor>;
      expect(descriptors, hasLength(2));
      for (final d in descriptors) {
        expect(d.disc, equals(1)); // senderHosted
      }
    });

    test('resolveParameterCapabilityDescriptors encodes an extracted pipelined reference '
        'as receiverAnswer', () {
      final h = _Harness();
      final cap = _FakeCapability();
      h.tryExtractCapabilityReference =
          (candidate) =>
              identical(candidate, cap)
                  ? const PipelinedCapabilityReference(
                    parentQuestionId: 17,
                    transformPath: [2, 3],
                  )
                  : null;

      final result = h.protocol.resolveParameterCapabilityDescriptors([
        cap,
      ], ensureActive: () {});

      expect(result, isA<List<RpcCapabilityDescriptor>>());
      final descriptor = (result as List<RpcCapabilityDescriptor>).single;
      expect(descriptor.disc, equals(4));
      expect(descriptor.questionId, equals(17));
      expect(descriptor.path, equals([2, 3]));
    });

    test('resolveParameterCapabilityDescriptors falls back to async and threads '
        'ensureActive at entry and after the await', () async {
      final h = _Harness();
      final capA = _FakeCapability();
      final importId = Completer<int>();
      h.tryExtractCapabilityReference =
          (cap) =>
              identical(cap, capA)
                  ? ImportedCapabilityReference(importId.future)
                  : null;

      var ensureActiveCalls = 0;
      final result = h.protocol.resolveParameterCapabilityDescriptors([
        capA,
      ], ensureActive: () => ensureActiveCalls++);

      expect(result, isA<Future<List<RpcCapabilityDescriptor>>>());
      final callsBeforeResolve = ensureActiveCalls;
      expect(callsBeforeResolve, greaterThanOrEqualTo(1));

      importId.complete(9);
      final descriptors = await (result as Future<List<RpcCapabilityDescriptor>>);

      expect(ensureActiveCalls, greaterThan(callsBeforeResolve));
      expect(descriptors.single.disc, equals(3)); // receiverHosted
      expect(descriptors.single.id, equals(9));
    });

    test('acquireCapabilityFromDescriptor routes none/senderHosted/senderPromise/'
        'receiverHosted to the right dependency', () {
      final h = _Harness();

      expect(
        h.protocol.acquireCapabilityFromDescriptor(const RpcCapabilityDescriptor.none()),
        isA<NullCapability>(),
      );

      h.protocol.acquireCapabilityFromDescriptor(
        const RpcCapabilityDescriptor.senderHosted(5),
      );
      expect(h.importTable.isTracked(5), isTrue);

      final promiseState = h.importTable.getOrCreateState(
        6,
      ); // capture before retain, to check isPromise
      h.protocol.acquireCapabilityFromDescriptor(
        const RpcCapabilityDescriptor.senderPromise(6),
      );
      expect(h.importTable.isTracked(6), isTrue);
      expect(promiseState.isPromise, isTrue);

      final exported = _FakeCapability();
      final exportId = h.exportTable.getOrCreate(exported);
      final lease = h.protocol.acquireCapabilityFromDescriptor(
        RpcCapabilityDescriptor.receiverHosted(exportId),
      );
      expect(identical(unwrapCapabilityLease(lease), exported), isTrue);
    });

    test('acquireCapabilityFromDescriptor delegates receiverAnswer construction to '
        'receiverAnswerCapability, normalizing an empty path to [0]', () {
      final h = _Harness();

      h.protocol.acquireCapabilityFromDescriptor(
        RpcCapabilityDescriptor.receiverAnswer(7, const [1, 2]),
      );
      h.protocol.acquireCapabilityFromDescriptor(
        RpcCapabilityDescriptor.receiverAnswer(8, const []),
      );

      // Compared component-wise, not via equals() on the whole record list:
      // a record's synthesized `==` calls `List.==` on its List field, which
      // is identity-based (inherited from Object), not the deep/structural
      // comparison `equals()` on a bare List would give.
      expect(h.receiverAnswerCalls, hasLength(2));
      expect(h.receiverAnswerCalls[0].$1, equals(7));
      expect(h.receiverAnswerCalls[0].$2, equals([1, 2]));
      // Empty path normalized to a single hop at pointer slot 0 — only
      // valid for a Bootstrap answer's capability, which has no wrapping
      // struct to traverse.
      expect(h.receiverAnswerCalls[1].$1, equals(8));
      expect(h.receiverAnswerCalls[1].$2, equals([0]));
    });

    test('handleResolve registers an embargo and sends a senderLoopback '
        'Disembargo before resolving, when the replacement is local and the '
        'import already received a call', () {
      final h = _Harness();
      final state = h.importTable.retain(7);
      state.receivedCall = true;

      final exported = _FakeCapability();
      final exportId = h.exportTable.getOrCreate(exported);
      // tryExtractCapabilityReference defaults to `null`, so the decoded
      // receiverHosted replacement counts as local.
      final msg = parseRpcMessage(
        buildResolveCapMessage(promiseId: 7, capDisc: 3, capId: exportId),
      );

      h.protocol.handleResolve(msg);

      expect(h.embargoTable.count, equals(1));
      expect(h.sentBytes, hasLength(1));
      final sent = parseRpcMessage(h.sentBytes.single);
      expect(sent.type, equals(RpcMessageType.disembargo));
      expect(sent.disembargoContextDisc, equals(0)); // senderLoopback
    });

    test('handleResolve skips Disembargo for a same-connection peer '
        'capability even when no reusable reference can be extracted', () {
      final h = _Harness();
      final state = h.importTable.retain(7);
      state.receivedCall = true;
      h.tryExtractCapabilityReference = (cap) => null;
      h.isSameConnectionPeerCapability = (cap) => true;

      final exported = _FakeCapability();
      final exportId = h.exportTable.getOrCreate(exported);
      final msg = parseRpcMessage(
        buildResolveCapMessage(promiseId: 7, capDisc: 3, capId: exportId),
      );

      h.protocol.handleResolve(msg);

      expect(h.embargoTable.count, isZero);
      expect(h.sentBytes, isEmpty);
      expect(state.replacement, isNotNull);
    });
  });
}
