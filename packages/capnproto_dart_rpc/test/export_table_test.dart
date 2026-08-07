import 'dart:async';

import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/export_table.dart';
import 'package:test/test.dart';

class _FakeCapability extends Capability {
  bool disposed = false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('ExportTable', () {
    test('retainOrCreateExportId dedupes by identity, bumping the remote refcount '
        'instead of allocating a new export id', () {
      final table = ExportTable();
      final cap = _FakeCapability();

      final id1 = table.retainOrCreateExportId(cap);
      expect(table.remoteRefCountFor(id1), equals(1));

      final id2 = table.retainOrCreateExportId(cap);
      expect(id2, equals(id1));
      expect(table.remoteRefCountFor(id1), equals(2));
      expect(table.count, equals(1));
    });

    test('retainOrCreateExportId for two distinct identities allocates two distinct '
        'export ids', () {
      final table = ExportTable();
      final capA = _FakeCapability();
      final capB = _FakeCapability();

      final idA = table.retainOrCreateExportId(capA);
      final idB = table.retainOrCreateExportId(capB);

      expect(idA, isNot(equals(idB)));
      expect(table.count, equals(2));
    });

    test('releaseReferences only disposes the export once the remote refcount '
        'reaches zero', () async {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.retainOrCreateExportId(cap);
      table.retainOrCreateExportId(cap); // remoteRefCount now 2.

      Capability? disposedLease;
      void disposeIgnoringErrors(Capability c) {
        disposedLease = c;
        c.dispose();
      }

      table.releaseReferences(id, 1, disposeIgnoringErrors);
      expect(table.remoteRefCountFor(id), equals(1));
      expect(disposedLease, isNull);
      expect(cap.disposed, isFalse);
      expect(table.getCapability(id), same(cap));

      table.releaseReferences(id, 1, disposeIgnoringErrors);
      expect(table.remoteRefCountFor(id), isNull);
      expect(table.getCapability(id), isNull);
      expect(disposedLease, isNotNull);
      // releaseReferences disposes ExportTable's own CapabilityLease
      // (not `cap` directly), which — since it was the only lease acquired
      // for `cap` — cascades into disposing `cap` itself once the shared
      // refcount reaches zero.
      expect(cap.disposed, isTrue);
    });

    test('releaseReferences with a referenceCount greater than 1 releases that '
        'many references in one call', () {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.retainOrCreateExportId(cap);
      table.retainOrCreateExportId(cap);
      table.retainOrCreateExportId(cap); // remoteRefCount now 3.

      table.releaseReferences(id, 3, (c) => c.dispose());
      expect(table.getCapability(id), isNull);
      expect(cap.disposed, isTrue);
    });

    test('releaseReference releases exactly one reference, unconditionally', () {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.retainOrCreateExportId(cap);
      table.retainOrCreateExportId(cap); // remoteRefCount now 2.

      table.releaseReference(id, (c) => c.dispose());
      expect(table.remoteRefCountFor(id), equals(1));
      expect(cap.disposed, isFalse);
    });

    test('releaseReferences for an export id that is not (or no longer) exported '
        'is a no-op', () {
      final table = ExportTable();
      var disposeCalls = 0;
      table.releaseReferences(42, 1, (c) => disposeCalls++);
      expect(disposeCalls, equals(0));
    });

    test('registerBootstrap starts the remote refcount at zero; the first '
        'retainExisting brings it to one', () {
      final table = ExportTable();
      final cap = _FakeCapability();
      table.registerBootstrap(cap);

      expect(table.remoteRefCountFor(0), equals(0));
      final retained = table.retainExisting(0);
      expect(retained, same(cap));
      expect(table.remoteRefCountFor(0), equals(1));
    });

    test('isCurrentIdentity reflects whether exportId still refers to the '
        'expected capability', () {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.retainOrCreateExportId(cap);

      expect(table.isCurrentIdentity(id, cap), isTrue);
      table.releaseReference(id, (c) => c.dispose());
      expect(table.isCurrentIdentity(id, cap), isFalse);
    });

    test('tearDown disposes every still-exported capability and clears the '
        'table', () {
      final table = ExportTable();
      final capA = _FakeCapability();
      final capB = _FakeCapability();
      table.retainOrCreateExportId(capA);
      table.retainOrCreateExportId(capB);

      table.tearDown((c) => c.disposeForConnectionTeardown());
      expect(table.count, equals(0));
      expect(capA.disposed, isTrue);
      expect(capB.disposed, isTrue);
    });

    test('tearDown abandons unresolved deferred exports without leaking a late resolution', () async {
      final table = ExportTable();
      final resolution = Completer<Capability>();
      final deferred = DeferredCapability(resolution.future);
      final resolved = _FakeCapability();
      table.retainOrCreateExportId(deferred);

      table.tearDown((cap) => cap.disposeForConnectionTeardown());
      await deferred.dispose().timeout(const Duration(seconds: 1));

      resolution.complete(resolved);
      await Future<void>.delayed(Duration.zero);
      expect(resolved.disposed, isTrue);
    });

    test('tearDown leaves an unresolved deferred identity alive while another lease exists', () async {
      final table = ExportTable();
      final resolution = Completer<Capability>();
      final deferred = DeferredCapability(resolution.future);
      final independentLease = acquireCapabilityLease(deferred);
      final resolved = _FakeCapability();
      table.retainOrCreateExportId(deferred);

      table.tearDown((cap) => cap.disposeForConnectionTeardown());

      var independentDisposeCompleted = false;
      final independentDispose = independentLease.dispose()
        ..then((_) => independentDisposeCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(independentDisposeCompleted, isFalse);

      resolution.complete(resolved);
      await independentDispose.timeout(const Duration(seconds: 1));
      expect(resolved.disposed, isTrue);
    });

    test('promise-resolution scheduling tracks watchers without affecting '
        'export state', () {
      final table = ExportTable();
      expect(table.markPromiseResolutionScheduled(5), isTrue);
      expect(table.markPromiseResolutionScheduled(5), isFalse); // already scheduled.
      table.clearPromiseResolutionScheduled(5);
      expect(table.markPromiseResolutionScheduled(5), isTrue); // can be scheduled again.
    });
  });
}
