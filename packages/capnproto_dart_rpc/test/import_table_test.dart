import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/capabilities/import_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:test/test.dart';

class _FakeCapability extends Capability {
  bool disposed = false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('ImportTable', () {
    test('duplicate retain/release: the import stays tracked until every '
        'retain has a matching release', () {
      final table = ImportTable();
      table.retain(7);
      table.retain(7);
      expect(table.isTracked(7), isTrue);

      var disposeCalls = 0;
      table.decrementRefcount(7, (c) => disposeCalls++);
      expect(table.isTracked(7), isTrue, reason: 'one reference remains');
      expect(disposeCalls, equals(0));

      table.decrementRefcount(7, (c) => disposeCalls++);
      expect(table.isTracked(7), isFalse);
    });

    test('decrementRefcount for an import with no outstanding reference is '
        'a no-op', () {
      final table = ImportTable();
      var disposeCalls = 0;
      table.decrementRefcount(99, (c) => disposeCalls++);
      expect(disposeCalls, equals(0));
      expect(table.isTracked(99), isFalse);
    });

    test('replacement disposal: once every retain for a resolved import is '
        'released, its cached replacement capability is disposed exactly '
        'once', () {
      final table = ImportTable();
      final replacement = _FakeCapability();
      final state = table.retain(3, isPromise: true);
      table.retain(3); // a second wrapper sharing the same import.
      state.resolveCapability(replacement);

      final disposed = <Capability>[];
      table.decrementRefcount(3, disposed.add);
      expect(disposed, isEmpty, reason: 'one reference still outstanding');
      expect(replacement.disposed, isFalse);

      table.decrementRefcount(3, disposed.add);
      expect(disposed, equals([replacement]));
      expect(table.isTracked(3), isFalse);
    });

    test('an import that never resolved to a replacement disposes nothing '
        'when its last reference is released', () {
      final table = ImportTable();
      table.retain(4);
      var disposeCalls = 0;
      table.decrementRefcount(4, (c) => disposeCalls++);
      expect(disposeCalls, equals(0));
    });

    test('retain reuses the same ImportState across calls for the same id, '
        'and isPromise sticks once set', () {
      final table = ImportTable();
      final first = table.retain(1);
      final second = table.retain(1, isPromise: true);
      expect(identical(first, second), isTrue);
      expect(first.isPromise, isTrue);

      // A later plain (non-promise) retain must not clear isPromise once set.
      final third = table.retain(1);
      expect(third.isPromise, isTrue);
    });

    test('getOrCreateState creates tracking state without bumping the refcount', () {
      final table = ImportTable();
      final state = table.getOrCreateState(2);
      expect(identical(table.getOrCreateState(2), state), isTrue);
      // Not retained, so isTracked (which reflects the refcount map) stays
      // false — getOrCreateState alone never holds a reference.
      expect(table.isTracked(2), isFalse);
    });

    test('markBroken/throwIfBroken: a broken import throws the recorded '
        'error on every check until it is fully released', () {
      final table = ImportTable();
      table.retain(5);
      expect(() => table.throwIfBroken(5), returnsNormally);

      final err = RpcException('promise rejected');
      table.markBroken(5, err);
      expect(() => table.throwIfBroken(5), throwsA(same(err)));

      table.decrementRefcount(5, (c) {});
      expect(() => table.throwIfBroken(5), returnsNormally);
      expect(table.brokenCount, equals(0));
    });

    test('releaseAndBatch applies decrementRefcount and batches a Release '
        'count, coalescing repeated calls before takeBatchedReleases', () {
      final table = ImportTable();
      table.retain(6);
      table.retain(6);
      table.retain(6);

      expect(table.releaseAndBatch(6, (c) {}), isTrue);
      expect(table.releaseAndBatch(6, (c) {}), isTrue);
      expect(table.batchedReleaseImportCount, equals(1));

      final batched = table.takeBatchedReleases();
      expect(batched, equals({6: 2}));
      expect(table.batchedReleaseImportCount, equals(0));
      // A second take before anything new happens hands back nothing.
      expect(table.takeBatchedReleases(), isEmpty);
    });

    test('releaseAndBatch for an import with no outstanding reference '
        'batches nothing and returns false', () {
      final table = ImportTable();
      expect(table.releaseAndBatch(123, (c) {}), isFalse);
      expect(table.batchedReleaseImportCount, equals(0));
    });

    test('tearDown drops every import and broken-promise entry', () {
      final table = ImportTable();
      table.retain(1);
      table.markBroken(1, RpcException('x'));
      table.retain(2);

      table.tearDown();
      expect(table.count, equals(0));
      expect(table.brokenCount, equals(0));
      expect(table.isTracked(1), isFalse);
      expect(table.isTracked(2), isFalse);
    });
  });
}
