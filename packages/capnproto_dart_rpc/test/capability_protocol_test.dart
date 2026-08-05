import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/capability_protocol.dart';
import 'package:capnproto_dart_rpc/src/rpc/embargo_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/export_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/question_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_proto.dart';
import 'package:capnproto_dart_rpc/src/rpc/wire_capability_context.dart';
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
/// is genuinely testable standalone. `classifyCapability` defaults to
/// reporting everything as [NotWireCapability] (i.e. genuinely local),
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

  /// Settable per test — defaults to "connection never closes".
  bool Function() isClosed = () => false;

  /// Settable per test — defaults to "nothing classifies as a wire
  /// capability", matching a real connection's answer for any capability
  /// it doesn't itself construct.
  WireCapabilityKind Function(Capability cap) classifyCapability =
      (cap) => const NotWireCapability();

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
    classifyCapability: (cap) => classifyCapability(cap),
    importedCapabilityFromState: (state) => _FakeCapability(),
    receiverAnswerCapability: (qid, path) => _FakeCapability(),
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

    test('resolveCapTableMaybeSync resolves synchronously when every '
        'capability classifies as NotWireCapability', () {
      final h = _Harness();
      final capA = _FakeCapability();
      final capB = _FakeCapability();

      final result = h.protocol.resolveCapTableMaybeSync(
        [capA, capB],
        ensureActive: () {},
      );

      expect(result, isA<List<RpcCapDescriptor>>());
      final descriptors = result as List<RpcCapDescriptor>;
      expect(descriptors, hasLength(2));
      for (final d in descriptors) {
        expect(d.disc, equals(1)); // senderHosted
      }
    });

    test('resolveCapTableMaybeSync falls back to async and threads '
        'ensureActive at entry and after the await', () async {
      final h = _Harness();
      final capA = _FakeCapability();
      final importId = Completer<int>();
      h.classifyCapability =
          (cap) =>
              identical(cap, capA)
                  ? ImportedWireCapability(importId.future)
                  : const NotWireCapability();

      var ensureActiveCalls = 0;
      final result = h.protocol.resolveCapTableMaybeSync(
        [capA],
        ensureActive: () => ensureActiveCalls++,
      );

      expect(result, isA<Future<List<RpcCapDescriptor>>>());
      final callsBeforeResolve = ensureActiveCalls;
      expect(callsBeforeResolve, greaterThanOrEqualTo(1));

      importId.complete(9);
      final descriptors = await (result as Future<List<RpcCapDescriptor>>);

      expect(ensureActiveCalls, greaterThan(callsBeforeResolve));
      expect(descriptors.single.disc, equals(3)); // receiverHosted
      expect(descriptors.single.id, equals(9));
    });

    test('capabilityFromDescriptor routes none/senderHosted/senderPromise/'
        'receiverHosted to the right dependency', () {
      final h = _Harness();

      expect(
        h.protocol.capabilityFromDescriptor(const RpcCapDescriptor.none()),
        isA<NullCapability>(),
      );

      h.protocol.capabilityFromDescriptor(
        const RpcCapDescriptor.senderHosted(5),
      );
      expect(h.importTable.isTracked(5), isTrue);

      final promiseState =
          h.importTable.stateFor(6); // capture before retain, to check isPromise
      h.protocol.capabilityFromDescriptor(
        const RpcCapDescriptor.senderPromise(6),
      );
      expect(h.importTable.isTracked(6), isTrue);
      expect(promiseState.isPromise, isTrue);

      final exported = _FakeCapability();
      final exportId = h.exportTable.getOrCreate(exported);
      final vended = h.protocol.capabilityFromDescriptor(
        RpcCapDescriptor.receiverHosted(exportId),
      );
      expect(identical(unwrapVendedCapability(vended), exported), isTrue);
    });

    test('handleResolve registers an embargo and sends a senderLoopback '
        'Disembargo before resolving, when the replacement is local and the '
        'import already received a call', () {
      final h = _Harness();
      final state = h.importTable.retain(7);
      state.receivedCall = true;

      final exported = _FakeCapability();
      final exportId = h.exportTable.getOrCreate(exported);
      // classifyCapability's default (NotWireCapability for everything)
      // means the decoded receiverHosted replacement counts as local.
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
  });
}
