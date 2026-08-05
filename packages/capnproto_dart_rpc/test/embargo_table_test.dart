import 'dart:async';

import 'package:capnproto_dart_rpc/src/rpc/capabilities/embargo_table.dart';
import 'package:capnproto_dart_rpc/src/rpc/rpc_exception.dart';
import 'package:test/test.dart';

void main() {
  group('EmbargoTable', () {
    test(
      'register then resolve completes the completer and drops tracking',
      () {
        final table = EmbargoTable();
        final completer = Completer<void>();
        final id = table.register(completer);
        expect(table.count, equals(1));

        table.resolve(id);
        expect(completer.isCompleted, isTrue);
        expect(table.count, equals(0));
      },
    );

    test('resolve for an unknown/already-resolved id is a no-op', () {
      final table = EmbargoTable();
      final completer = Completer<void>();
      final id = table.register(completer);

      table.resolve(id);
      // Second resolve for the same (now untracked) id must not throw and
      // must not touch the already-completed completer again.
      expect(() => table.resolve(id), returnsNormally);
      expect(() => table.resolve(id + 1), returnsNormally);
    });

    test(
      'resolve arriving before the timeout cancels it: the completer '
      'settles successfully and a late timer firing never overwrites that',
      () async {
        final table = EmbargoTable();
        final completer = Completer<void>();
        final id = table.register(
          completer,
          timeout: const Duration(milliseconds: 30),
        );

        table.resolve(id);
        expect(completer.isCompleted, isTrue);
        await completer.future; // must not throw — resolve() completed it.

        // Wait past when the timeout would have fired if it weren't canceled.
        // If it weren't, EmbargoTable's own isCompleted guard would still
        // prevent a second completion, but the point of this test is that the
        // race is actually won by resolve(), not merely papered over.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(table.count, equals(0));
      },
    );

    test(
      'timeout firing before resolve() fails the completer, and a later '
      'resolve() call for the same (now-expired) id is a safe no-op',
      () async {
        final table = EmbargoTable();
        final completer = Completer<void>();
        final id = table.register(
          completer,
          timeout: const Duration(milliseconds: 20),
        );

        await expectLater(completer.future, throwsA(isA<RpcException>()));
        expect(table.count, equals(0));

        // The peer's receiverLoopback reply finally arrives after the local
        // timeout already gave up on it — resolve() must not throw or try to
        // re-complete the completer.
        expect(() => table.resolve(id), returnsNormally);
      },
    );

    test(
      'tearDown fails every still-pending embargo and clears the table',
      () async {
        final table = EmbargoTable();
        final c1 = Completer<void>();
        final c2 = Completer<void>();
        table.register(c1, timeout: const Duration(seconds: 30));
        table.register(c2);
        expect(table.count, equals(2));

        final err = StateError('connection torn down');
        table.tearDown(err);

        expect(table.count, equals(0));
        await expectLater(c1.future, throwsA(same(err)));
        await expectLater(c2.future, throwsA(same(err)));
      },
    );

    test(
      'tearDown does not touch an embargo already resolved before it ran',
      () async {
        final table = EmbargoTable();
        final completer = Completer<void>();
        final id = table.register(completer);
        table.resolve(id);

        // Must not throw trying to complete an already-completed completer.
        expect(() => table.tearDown(StateError('torn down')), returnsNormally);
        await completer.future; // still resolves cleanly, no error.
      },
    );
  });
}
