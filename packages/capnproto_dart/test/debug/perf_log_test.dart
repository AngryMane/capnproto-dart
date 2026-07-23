import 'package:capnproto_dart/src/debug/perf_log.dart';
import 'package:test/test.dart';

void main() {
  group('timePerf', () {
    test('returns the wrapped body\'s result unchanged', () {
      expect(timePerf('test-op', () => 42), equals(42));
      expect(timePerf('test-op', () => 'hello'), equals('hello'));
      expect(timePerf('test-op', () => null), isNull);
    });

    test('runs the body exactly once', () {
      var calls = 0;
      timePerf('test-op', () {
        calls++;
        return calls;
      });
      expect(calls, equals(1));
    });

    test('propagates exceptions thrown by the body', () {
      expect(
        () => timePerf('test-op', () => throw StateError('boom')),
        throwsStateError,
      );
    });

    test(
      'kDebugLoggingEnabled is true under `dart test` (JIT/debug)',
      () {
        // dart test always runs under the JIT (dart.vm.product defaults to
        // false), so this is really asserting the constant reads correctly
        // in this build mode — release-mode behavior (false) is verified
        // separately via `dart compile exe`, not exercisable from a test
        // run, which is itself always JIT.
        expect(kDebugLoggingEnabled, isTrue);
      },
    );
  });
}
