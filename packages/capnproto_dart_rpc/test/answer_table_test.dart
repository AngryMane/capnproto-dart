import 'dart:async';
import 'dart:typed_data';

import 'package:capnproto_dart/capnproto_dart.dart';
import 'package:capnproto_dart_rpc/src/capability/capability.dart';
import 'package:capnproto_dart_rpc/src/rpc/calls/answer_table.dart';
import 'package:test/test.dart';

ResolvedAnswer _answer([List<Capability> caps = const []]) =>
    ResolvedAnswer(Uint8List(0), caps);

void main() {
  group('AnswerTable', () {
    test('Finish arriving while dispatch is still pending: applyPeerFinish() '
        'returns null, marks the answer finished, and cancels the live '
        'dispatch — the eventual dispatch result must then be dropped '
        'instead of resurrecting answer state', () async {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      final cancellation = DispatchCancellationController();
      pending.future.ignore();
      table.recordPendingAnswer(1, pending.future, cancellation);

      final resultExportIds = table.applyPeerFinish(1);
      expect(resultExportIds, isNull);
      expect(cancellation.context.isCanceled, isTrue);
      expect(
        table.isTracked(1),
        isTrue,
        reason: 'finished-before-completion is still tracked',
      );

      // The dispatch eventually settles — _executeIncomingDispatch calls clearPendingAnswer()
      // (a path that ends up recording nothing further) or
      // tryRecordAnswer()/tryRecordFailedAnswer() (a path
      // that does) to both drop dispatch-in-flight bookkeeping and learn
      // whether Finish already arrived, in one call.
      expect(table.clearPendingAnswer(1), isTrue);
      expect(table.isTracked(1), isFalse);
      // A second clear for the same qid must not resurrect anything, and
      // must not report "finished early" again now that it's untracked.
      expect(table.clearPendingAnswer(1), isFalse);
    });

    test('a second Finish for a qid already marked finished-before-'
        'completion is a no-op — it must not double-cancel the dispatch '
        'or resurrect any state', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      final cancellation = DispatchCancellationController();
      pending.future.ignore();
      table.recordPendingAnswer(1, pending.future, cancellation);

      expect(table.applyPeerFinish(1), isNull);
      expect(table.applyPeerFinish(1), isNull);
      expect(table.isTracked(1), isTrue);
      expect(table.clearPendingAnswer(1), isTrue);
    });

    test('Finish for an unknown qid is a no-op returning null', () {
      final table = AnswerTable();
      expect(table.applyPeerFinish(42), isNull);
    });

    test('clearAnswerForNoFinishNeeded removes only completed local '
        'bookkeeping and does not cancel its settled dispatch', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      final cancellation = DispatchCancellationController();
      pending.future.ignore();
      table.recordPendingAnswer(1, pending.future, cancellation);
      expect(table.tryRecordAnswer(1, resolved: _answer()), isTrue);

      table.clearAnswerForNoFinishNeeded(1);

      expect(table.isTracked(1), isFalse);
      expect(cancellation.context.isCanceled, isFalse);
    });

    test('clearAnswerForNoFinishNeeded is a no-op when a reentrant peer '
        'Finish already consumed the completed answer', () {
      final table = AnswerTable();
      table.recordAnswer(2, resolved: _answer());
      expect(table.applyPeerFinish(2), equals(const []));

      expect(() => table.clearAnswerForNoFinishNeeded(2), returnsNormally);
      expect(table.isTracked(2), isFalse);
    });

    test('clearAnswerForNoFinishNeeded rejects a pending answer without '
        'canceling or removing it', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      final cancellation = DispatchCancellationController();
      pending.future.ignore();
      table.recordPendingAnswer(3, pending.future, cancellation);

      expect(() => table.clearAnswerForNoFinishNeeded(3), throwsStateError);
      expect(table.isTracked(3), isTrue);
      expect(cancellation.context.isCanceled, isFalse);
      table.clearPendingAnswer(3);
    });

    test('clearAnswerForNoFinishNeeded rejects a completed answer with '
        'result exports and leaves it for peer Finish', () {
      final table = AnswerTable();
      table.recordAnswer(4, resolved: _answer(), resultExportIds: [7]);

      expect(() => table.clearAnswerForNoFinishNeeded(4), throwsStateError);
      expect(table.isTracked(4), isTrue);
      expect(table.applyPeerFinish(4), equals([7]));
    });

    test(
      'tryRecordAnswer installs the answer atomically for a '
      'live dispatch: qid is never observably untracked, unlike calling '
      'clearPendingAnswer and recording the answer as two separate calls',
      () {
        final table = AnswerTable();
        final pending = Completer<ResolvedAnswer>();
        pending.future.ignore();
        table.recordPendingAnswer(
          1,
          pending.future,
          DispatchCancellationController(),
        );

        final resolved = _answer();
        final completed = table.tryRecordAnswer(
          1,
          resolved: resolved,
          resultExportIds: [7],
        );
        expect(completed, isTrue);
        expect(table.isTracked(1), isTrue);
        expect(table.resolvedFor(1), same(resolved));
        expect(table.pendingFor(1), isNull, reason: 'no longer pending');
        expect(table.applyPeerFinish(1), equals([7]));
      },
    );

    test('tryRecordAnswer for a qid finished early: returns '
        'false, drops every trace of it, and does not record the answer '
        '— the caller must discard the dispatch result instead', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      table.recordPendingAnswer(
        1,
        pending.future,
        DispatchCancellationController(),
      );
      expect(
        table.applyPeerFinish(1),
        isNull,
      ); // Finish arrives before dispatch settles.

      final completed = table.tryRecordAnswer(1, resolved: _answer());
      expect(completed, isFalse);
      expect(table.isTracked(1), isFalse);
      expect(table.resolvedFor(1), isNull);
    });

    test('tryRecordFailedAnswer installs the retained error atomically '
        'for a live dispatch', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      table.recordPendingAnswer(
        2,
        pending.future,
        DispatchCancellationController(),
      );

      final error = const CapnpException('boom');
      final completed = table.tryRecordFailedAnswer(2, error);
      expect(completed, isTrue);
      expect(table.errorFor(2), same(error));
      expect(table.applyPeerFinish(2), equals(const []));
    });

    test('tryRecordFailedAnswer for a qid finished early: returns '
        'false and does not retain the error', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      table.recordPendingAnswer(
        2,
        pending.future,
        DispatchCancellationController(),
      );
      expect(table.applyPeerFinish(2), isNull);

      final completed = table.tryRecordFailedAnswer(
        2,
        const CapnpException('boom'),
      );
      expect(completed, isFalse);
      expect(table.isTracked(2), isFalse);
      expect(table.errorFor(2), isNull);
    });

    test('Finish arriving for a qid with no pending dispatch (already '
        'resolved) returns its recorded result export ids and clears the '
        'resolved answer', () {
      final table = AnswerTable();
      table.recordAnswer(2, resolved: _answer(), resultExportIds: [10, 11]);

      final resultExportIds = table.applyPeerFinish(2);
      expect(resultExportIds, equals([10, 11]));
      expect(table.resolvedFor(2), isNull);
      expect(table.isTracked(2), isFalse);
    });

    test('Finish for a failed-and-retained answer returns an empty export '
        'id list and drops the retained error', () {
      final table = AnswerTable();
      table.tryRecordFailedAnswer(2, const CapnpException('boom'));
      expect(table.errorFor(2), isNotNull);

      final resultExportIds = table.applyPeerFinish(2);
      expect(resultExportIds, equals(const []));
      expect(table.errorFor(2), isNull);
      expect(table.isTracked(2), isFalse);
    });

    test('duplicate question id: isTracked reports true for every distinct '
        'answer-lifecycle state a peer could illegally collide a fresh Call '
        'against', () {
      final table = AnswerTable();
      expect(table.isTracked(3), isFalse);

      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      table.recordPendingAnswer(
        3,
        pending.future,
        DispatchCancellationController(),
      );
      expect(table.isTracked(3), isTrue, reason: 'pending answer');
      expect(table.clearPendingAnswer(3), isFalse);
      expect(table.isTracked(3), isFalse);

      table.recordAnswer(3, resolved: _answer());
      expect(table.isTracked(3), isTrue, reason: 'resolved, awaiting Finish');
      table.applyPeerFinish(3);
      expect(table.isTracked(3), isFalse);

      table.tryRecordFailedAnswer(3, const CapnpException('boom'));
      expect(table.isTracked(3), isTrue, reason: 'failed answer retained');
    });

    test('recordAnswer with no resolved answer still tracks the qid '
        '(so duplicate reuse is rejected) but reports no pipelining data', () {
      final table = AnswerTable();
      table.recordAnswer(4);
      expect(table.isTracked(4), isTrue);
      expect(table.resolvedFor(4), isNull);
      expect(table.applyPeerFinish(4), equals(const []));
    });

    test('resolvedFor/pendingFor/errorFor each only report data for their '
        'own state, null for every other state and for an unknown qid', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();

      table.recordPendingAnswer(
        1,
        pending.future,
        DispatchCancellationController(),
      );
      expect(table.pendingFor(1), same(pending.future));
      expect(table.resolvedFor(1), isNull);
      expect(table.errorFor(1), isNull);

      final resolved = _answer();
      table.recordAnswer(2, resolved: resolved);
      expect(table.resolvedFor(2), same(resolved));
      expect(table.pendingFor(2), isNull);
      expect(table.errorFor(2), isNull);

      final error = const CapnpException('boom');
      table.tryRecordFailedAnswer(3, error);
      expect(table.errorFor(3), same(error));
      expect(table.resolvedFor(3), isNull);
      expect(table.pendingFor(3), isNull);

      expect(table.resolvedFor(999), isNull);
      expect(table.pendingFor(999), isNull);
      expect(table.errorFor(999), isNull);
    });

    test('count is the number of distinct tracked qids, regardless of which '
        'state each one is in', () {
      final table = AnswerTable();
      table.recordAnswer(1, resolved: _answer());
      table.tryRecordFailedAnswer(2, const CapnpException('x'));
      expect(table.count, equals(2));
    });

    test('cancellationCount reflects only live in-flight cancellation '
        'controllers, dropped once the dispatch settles', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      table.recordPendingAnswer(
        1,
        pending.future,
        DispatchCancellationController(),
      );
      expect(table.cancellationCount, equals(1));
      table.clearPendingAnswer(1);
      expect(table.cancellationCount, equals(0));
    });

    test('tearDown cancels every live dispatch and clears all tracked '
        'state', () {
      final table = AnswerTable();
      final pending = Completer<ResolvedAnswer>();
      pending.future.ignore();
      final cancellation = DispatchCancellationController();
      table.recordPendingAnswer(1, pending.future, cancellation);
      table.recordAnswer(2, resolved: _answer());
      table.tryRecordFailedAnswer(3, const CapnpException('x'));

      table.tearDown();
      expect(cancellation.context.isCanceled, isTrue);
      expect(table.count, equals(0));
      expect(table.cancellationCount, equals(0));
    });
  });
}
