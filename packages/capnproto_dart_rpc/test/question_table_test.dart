import 'package:capnproto_dart_rpc/src/rpc/question_table.dart';
import 'package:test/test.dart';

void main() {
  group('QuestionTable', () {
    test('abandon drops both the Return completer and the sent completer, '
        'so a stray late Return for that qid is no longer recognized', () {
      final table = QuestionTable();
      final question = table.allocate();
      final completer = question.returnCompleter!;
      final sentCompleter = question.sentCompleter!;
      final qid = question.id;

      expect(table.pendingCount, equals(1));
      expect(table.pendingSentCount, equals(1));
      expect(table.sentCompleterFor(qid), same(sentCompleter));

      table.abandon(qid);
      expect(table.pendingCount, equals(0));
      expect(table.pendingSentCount, equals(0));
      expect(table.sentCompleterFor(qid), isNull);
      expect(table.takeReturn(qid), isNull);
      // abandon() itself never touches the completers the caller already
      // holds — it only drops the table's own tracking of them.
      expect(completer.isCompleted, isFalse);
      expect(sentCompleter.isCompleted, isFalse);
    });

    test('markSent completes the sent completer and drops sent-tracking, '
        'without touching the Return completer', () {
      final table = QuestionTable();
      final question = table.allocate();
      final completer = question.returnCompleter!;
      final sentCompleter = question.sentCompleter!;
      final qid = question.id;

      table.markSent(qid);
      expect(sentCompleter.isCompleted, isTrue);
      expect(table.sentCompleterFor(qid), isNull);
      expect(table.pendingSentCount, equals(0));
      expect(table.pendingCount, equals(1), reason: 'still awaiting Return');
      expect(completer.isCompleted, isFalse);

      // Idempotent: marking an already-sent (or unknown) qid sent again
      // must not throw.
      expect(() => table.markSent(qid), returnsNormally);
    });

    test('tearDown fails every still-pending Return and sent completer, '
        'and clears the table', () async {
      final table = QuestionTable();
      final question1 = table.allocate();
      final completer1 = question1.returnCompleter!;
      final sentCompleter1 = question1.sentCompleter!;
      final question2 = table.allocate();
      final qid2 = question2.id;
      final completer2 = question2.returnCompleter!;
      final sentCompleter2 = question2.sentCompleter!;
      table.markSent(qid2); // qid2 has no outstanding sent completer.

      final err = StateError('connection torn down');
      table.tearDown(err);

      expect(table.pendingCount, equals(0));
      expect(table.pendingSentCount, equals(0));
      await expectLater(completer1.future, throwsA(same(err)));
      await expectLater(sentCompleter1.future, throwsA(same(err)));
      await expectLater(completer2.future, throwsA(same(err)));
      // qid2's sent completer was already removed by markSent, so tearDown
      // has nothing left to fail for it — no exception either way.
      expect(sentCompleter2.isCompleted, isTrue);
    });

    test('tearDown also drops recorded param export ids — it clears every '
        'piece of state this table owns, not just the Return/sent '
        'completers', () {
      final table = QuestionTable();
      final question = table.allocate();
      final completer = question.returnCompleter!;
      final sentCompleter = question.sentCompleter!;
      final qid = question.id;
      completer.future.ignore();
      sentCompleter.future.ignore();
      table.recordParamExportIds(qid, [10, 11]);

      table.tearDown(StateError('connection torn down'));

      // Connection teardown discards the whole ExportTable too, so this
      // isn't needed to avoid a capability leak — but the table must not
      // claim to clear "all tracking" while silently leaving this behind.
      expect(table.takeParamExportIds(qid), isNull);
    });

    test('tearDown does not double-complete a Return completer the caller '
        'already settled itself', () async {
      final table = QuestionTable();
      final question = table.allocate();
      final completer = question.returnCompleter!;
      final sentCompleter = question.sentCompleter!;
      sentCompleter.future.ignore();
      final originalError = StateError('already failed');
      completer.completeError(originalError);
      completer.future.ignore();

      expect(() => table.tearDown(StateError('torn down')), returnsNormally);
      await expectLater(completer.future, throwsA(same(originalError)));
    });

    test('param export ids: recording an empty list stores nothing, so '
        'takeParamExportIds reports no entry to roll back or release', () {
      final table = QuestionTable();
      final question = table.allocate();
      final qid = question.id;

      table.recordParamExportIds(qid, const []);
      expect(table.takeParamExportIds(qid), isNull);
    });

    test('param export ids: a non-empty list round-trips through '
        'takeParamExportIds exactly once, then reports nothing on a second '
        'call for the same qid', () {
      final table = QuestionTable();
      final question = table.allocate();
      final qid = question.id;

      table.recordParamExportIds(qid, [5, 6, 7]);
      expect(table.takeParamExportIds(qid), equals([5, 6, 7]));
      expect(table.takeParamExportIds(qid), isNull);
    });

    test('allocateForBootstrap registers only a Return completer, with no '
        'matching sent-tracking entry', () {
      final table = QuestionTable();
      final question = table.allocateForBootstrap();
      final qid = question.id;
      final completer = question.returnCompleter!;

      expect(table.pendingCount, equals(1));
      expect(table.pendingSentCount, equals(0));
      expect(table.sentCompleterFor(qid), isNull);
      expect(table.takeReturn(qid), same(completer));
    });

    test('question ids are allocated monotonically and never reused across '
        'allocate()/allocateForBootstrap() calls', () {
      final table = QuestionTable();
      final qid1 = table.allocate().id;
      final qid2 = table.allocateForBootstrap().id;
      final qid3 = table.allocate().id;
      expect({qid1, qid2, qid3}.length, equals(3));
      expect(qid2, greaterThan(qid1));
      expect(qid3, greaterThan(qid2));
    });

    test('takeReturn removes and returns the Return completer for a '
        'tracked qid, and returns null for an unknown one', () {
      final table = QuestionTable();
      final question = table.allocate();
      final qid = question.id;
      final completer = question.returnCompleter!;

      expect(table.takeReturn(qid), same(completer));
      expect(table.takeReturn(qid), isNull);
      expect(table.takeReturn(9999), isNull);
    });
  });
}
