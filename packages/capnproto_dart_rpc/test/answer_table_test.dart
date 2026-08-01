import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/answer_table.dart';
import 'package:test/test.dart';

ResolvedAnswer _answer([List<Capability> caps = const []]) =>
    ResolvedAnswer(Uint8List(0), caps);

void main() {
  group('AnswerTable', () {
    test('Finish arriving while dispatch is still pending: finish() '
        'returns null, marks the answer finished, and cancels the live '
        'dispatch — the eventual dispatch result must then be dropped '
        'instead of resurrecting answer state', () async {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      final cancellation = DispatchCancellationController();
      table.trackPending(1, pending.future);
      table.trackCancellation(1, cancellation);
      pending.future.ignore();

      final resultExportIds = table.finish(1);
      expect(resultExportIds, isNull);
      expect(cancellation.context.isCanceled, isTrue);

      // The dispatch eventually settles — _runDispatch's own sequence is
      // dispatchSettled() first, then consumeIfAlreadyFinished() to decide
      // whether to drop the result instead of answering it.
      table.dispatchSettled(1);
      expect(table.consumeIfAlreadyFinished(1), isTrue);
      expect(table.isTracked(1), isFalse);
      // A second consume for the same qid must not resurrect anything.
      expect(table.consumeIfAlreadyFinished(1), isFalse);
    });

    test('Finish arriving for a qid with no pending dispatch (already '
        'resolved) returns its recorded result export ids and clears the '
        'resolved answer', () {
      final table = AnswerTable();
      table.setResolved(2, _answer());
      table.recordAnswered(2, [10, 11]);

      final resultExportIds = table.finish(2);
      expect(resultExportIds, equals([10, 11]));
      expect(table.resolvedFor(2), isNull);
      expect(table.isTracked(2), isFalse);
    });

    test('duplicate question id: isTracked reports true for every distinct '
        'answer-lifecycle state a peer could illegally collide a fresh Call '
        'against', () {
      final table = AnswerTable();
      expect(table.isTracked(3), isFalse);

      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      table.trackPending(3, pending.future);
      expect(table.isTracked(3), isTrue, reason: 'dispatch in flight');
      table.dispatchSettled(3);
      expect(table.isTracked(3), isFalse);

      table.setResolved(3, _answer());
      expect(table.isTracked(3), isTrue, reason: 'resolved, awaiting Finish');
      table.dropResolved(3);
      expect(table.isTracked(3), isFalse);

      table.recordAnswered(3, const []);
      expect(table.isTracked(3), isTrue, reason: 'answered, awaiting Finish');
      table.finish(3);
      expect(table.isTracked(3), isFalse);

      // recordError is only ever called alongside recordAnswered (the
      // sendResultsToYourself failure path in _runDispatch) — isTracked
      // relies on that pairing rather than checking _answerErrors itself,
      // so this asserts the pairing invariant holds, not just isTracked in
      // isolation.
      table.recordError(3, const CapnpException('boom'));
      table.recordAnswered(3, const []);
      expect(table.isTracked(3), isTrue, reason: 'dispatch failed, error retained');
    });

    test('isTracked does not, by itself, reflect a recorded error unless '
        'recordAnswered was also called for the same qid — the only real '
        'call site (_runDispatch\'s sendResultsToYourself failure path) '
        'always calls both together, so this is a latent gap rather than '
        'a reachable one; documented here so it stays visible if that '
        'pairing ever changes', () {
      final table = AnswerTable();
      table.recordError(4, const CapnpException('boom'));
      expect(table.isTracked(4), isFalse);
      expect(table.errorFor(4), isNotNull);
    });

    test('count is the union of every distinct qid across all tracked '
        'states, not a sum with duplicates', () {
      final table = AnswerTable();
      table.setResolved(1, _answer());
      table.recordAnswered(1, const []); // same qid, second map.
      table.recordError(2, const CapnpException('x'));
      expect(table.count, equals(2));
    });

    test('cancellationCount reflects only live in-flight cancellation '
        'controllers, dropped once the dispatch settles', () {
      final table = AnswerTable();
      table.trackCancellation(1, DispatchCancellationController());
      expect(table.cancellationCount, equals(1));
      table.dispatchSettled(1);
      expect(table.cancellationCount, equals(0));
    });

    test('tearDown cancels every live dispatch and clears all tracked '
        'state', () {
      final table = AnswerTable();
      final cancellation = DispatchCancellationController();
      table.trackCancellation(1, cancellation);
      table.setResolved(2, _answer());
      table.recordError(3, const CapnpException('x'));

      table.tearDown();
      expect(cancellation.context.isCanceled, isTrue);
      expect(table.count, equals(0));
      expect(table.cancellationCount, equals(0));
    });
  });
}
