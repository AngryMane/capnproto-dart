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
    test('getOrCreate dedupes by identity, bumping the remote refcount '
        'instead of allocating a new export id', () {
      final table = ExportTable();
      final cap = _FakeCapability();

      final id1 = table.getOrCreate(cap);
      expect(table.remoteRefCountFor(id1), equals(1));

      final id2 = table.getOrCreate(cap);
      expect(id2, equals(id1));
      expect(table.remoteRefCountFor(id1), equals(2));
      expect(table.count, equals(1));
    });

    test('getOrCreate for two distinct identities allocates two distinct '
        'export ids', () {
      final table = ExportTable();
      final capA = _FakeCapability();
      final capB = _FakeCapability();

      final idA = table.getOrCreate(capA);
      final idB = table.getOrCreate(capB);

      expect(idA, isNot(equals(idB)));
      expect(table.count, equals(2));
    });

    test('releaseRef only disposes the export once the remote refcount '
        'reaches zero', () async {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.getOrCreate(cap);
      table.getOrCreate(cap); // remoteRefCount now 2.

      Capability? disposedHandle;
      void disposeIgnoringErrors(Capability c) {
        disposedHandle = c;
        c.dispose();
      }

      table.releaseRef(id, 1, disposeIgnoringErrors);
      expect(table.remoteRefCountFor(id), equals(1));
      expect(disposedHandle, isNull);
      expect(cap.disposed, isFalse);
      expect(table.getCapability(id), same(cap));

      table.releaseRef(id, 1, disposeIgnoringErrors);
      expect(table.remoteRefCountFor(id), isNull);
      expect(table.getCapability(id), isNull);
      expect(disposedHandle, isNotNull);
      // releaseRef disposes ExportTable's own acquireCapabilityLease reference
      // (not `cap` directly), which — since it was the only lease acquired
      // for `cap` — cascades into disposing `cap` itself once the shared
      // refcount reaches zero.
      expect(cap.disposed, isTrue);
    });

    test('releaseRef with a referenceCount greater than 1 releases that '
        'many references in one call', () {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.getOrCreate(cap);
      table.getOrCreate(cap);
      table.getOrCreate(cap); // remoteRefCount now 3.

      table.releaseRef(id, 3, (c) => c.dispose());
      expect(table.getCapability(id), isNull);
      expect(cap.disposed, isTrue);
    });

    test('release() releases exactly one reference, unconditionally', () {
      final table = ExportTable();
      final cap = _FakeCapability();
      final id = table.getOrCreate(cap);
      table.getOrCreate(cap); // remoteRefCount now 2.

      table.release(id, (c) => c.dispose());
      expect(table.remoteRefCountFor(id), equals(1));
      expect(cap.disposed, isFalse);
    });

    test('releaseRef for an export id that is not (or no longer) exported '
        'is a no-op', () {
      final table = ExportTable();
      var disposeCalls = 0;
      table.releaseRef(42, 1, (c) => disposeCalls++);
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
      final id = table.getOrCreate(cap);

      expect(table.isCurrentIdentity(id, cap), isTrue);
      table.release(id, (c) => c.dispose());
      expect(table.isCurrentIdentity(id, cap), isFalse);
    });

    test('tearDown disposes every still-exported capability and clears the '
        'table', () {
      final table = ExportTable();
      final capA = _FakeCapability();
      final capB = _FakeCapability();
      table.getOrCreate(capA);
      table.getOrCreate(capB);

      table.tearDown((c) => c.dispose());
      expect(table.count, equals(0));
      expect(capA.disposed, isTrue);
      expect(capB.disposed, isTrue);
    });

    test('markScheduled/clearScheduled track sender-promise resolution '
        'watchers without affecting export state', () {
      final table = ExportTable();
      expect(table.markScheduled(5), isTrue);
      expect(table.markScheduled(5), isFalse); // already scheduled.
      table.clearScheduled(5);
      expect(table.markScheduled(5), isTrue); // can be scheduled again.
    });
  });
}
