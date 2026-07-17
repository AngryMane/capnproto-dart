import 'dart:async';

import 'package:capnproto_dart_rpc/src/rpc/flow_controller.dart';
import 'package:test/test.dart';

void main() {
  group('FlowController', () {
    test('send resolves immediately while under the window', () async {
      final fc = FlowController(windowSize: 100);
      final ack = Completer<void>();
      var resolved = false;
      unawaited(fc.send(10, ack.future).then((_) => resolved = true));
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isTrue);
      expect(fc.debugInFlight, equals(10));
    });

    test(
      'send blocks once in-flight bytes reach the window, and resolves '
      'once an earlier call is acked',
      () async {
        // The window is extended by the largest message seen so far (see
        // FlowController doc comment), so use uniform message sizes here —
        // otherwise the first message's own size would keep extending the
        // effective limit and nothing would ever block. With windowSize=10
        // and 5-byte messages: send 1 -> in-flight 5 (< 10+5, ready); send 2
        // -> in-flight 10 (< 15, ready); send 3 -> in-flight 15 (not < 15,
        // blocked).
        final fc = FlowController(windowSize: 10);
        final ack1 = Completer<void>();
        final ack2 = Completer<void>();
        final ack3 = Completer<void>();

        var firstResolved = false;
        unawaited(fc.send(5, ack1.future).then((_) => firstResolved = true));
        var secondResolved = false;
        unawaited(fc.send(5, ack2.future).then((_) => secondResolved = true));
        await Future<void>.delayed(Duration.zero);
        expect(firstResolved, isTrue);
        expect(secondResolved, isTrue);
        expect(fc.debugInFlight, equals(10));

        var thirdResolved = false;
        unawaited(fc.send(5, ack3.future).then((_) => thirdResolved = true));
        await Future<void>.delayed(Duration.zero);
        expect(
          thirdResolved,
          isFalse,
          reason: '15 in-flight bytes is not < window(10) + maxMessage(5)',
        );
        expect(fc.debugInFlight, equals(15));

        // Acking the first call frees 5 bytes, bringing in-flight to 10,
        // which is back under the limit — the third send must now unblock.
        ack1.complete();
        await Future<void>.delayed(Duration.zero);
        expect(thirdResolved, isTrue);
        expect(fc.debugInFlight, equals(10));

        ack2.complete();
        ack3.complete();
        await Future<void>.delayed(Duration.zero);
        expect(fc.debugInFlight, equals(0));
      },
    );

    test(
      'a message larger than the window is still sendable, and the window '
      'is extended by its size to avoid permanently stalling',
      () async {
        final fc = FlowController(windowSize: 10);
        final bigAck = Completer<void>();
        var bigResolved = false;
        unawaited(fc.send(50, bigAck.future).then((_) => bigResolved = true));
        await Future<void>.delayed(Duration.zero);
        // The very first send is never blocked by its own size.
        expect(bigResolved, isTrue);

        // A second, small send now competes against the (still outstanding)
        // 50-byte message. window(10) + maxMessageSize(50) = 60, and
        // in-flight is 50, so there's still room for a small follow-up.
        final smallAck = Completer<void>();
        var smallResolved = false;
        unawaited(
          fc.send(5, smallAck.future).then((_) => smallResolved = true),
        );
        await Future<void>.delayed(Duration.zero);
        expect(smallResolved, isTrue);

        bigAck.complete();
        smallAck.complete();
      },
    );

    test(
      'a failed ack fails currently-blocked sends and poisons future sends',
      () async {
        final fc = FlowController(windowSize: 5);
        final ack1 = Completer<void>();
        unawaited(fc.send(5, ack1.future));
        await Future<void>.delayed(Duration.zero);

        // This one is blocked (in-flight already at the window). Attach a
        // listener immediately (rather than after triggering the error
        // below) so the pending rejection isn't briefly unobserved and
        // flagged as an unhandled zone error.
        final blockedResult = fc.send(5, Completer<void>().future);
        Object? capturedError;
        unawaited(blockedResult.catchError((Object e) => capturedError = e));

        ack1.completeError(StateError('write failed'));
        await Future<void>.delayed(Duration.zero);

        expect(capturedError, isA<StateError>());

        // Once poisoned, even a brand-new send fails immediately rather than
        // silently continuing to buffer behind a stream that's already broken.
        await expectLater(
          fc.send(1, Future<void>.value()),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}
