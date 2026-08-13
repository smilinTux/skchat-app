import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/skcapstone_client.dart';

/// CM P2.5 unit tests for the change-management model/wire helpers added to
/// SKCapstoneClient: no Dio/network involved, these are pure functions and
/// JSON parsers, matching the plain `test()` style already used by
/// device_label_test.dart / device_recovery_codec_test.dart in this folder.
void main() {
  group('buildScheduleBody (deploy_mode lock)', () {
    test('is always "confirm" regardless of asap/window inputs', () {
      final asapBody = buildScheduleBody(asap: true, note: 'go now');
      final windowedBody = buildScheduleBody(
        windowStart: DateTime.utc(2026, 8, 20, 2),
        windowEnd: DateTime.utc(2026, 8, 20, 4),
        note: 'weekend window',
      );
      final emptyBody = buildScheduleBody();

      expect(asapBody['deploy_mode'], 'confirm');
      expect(windowedBody['deploy_mode'], 'confirm');
      expect(emptyBody['deploy_mode'], 'confirm');
    });

    test('asap:true omits window_start/window_end', () {
      final body = buildScheduleBody(
        asap: true,
        windowStart: DateTime.utc(2026, 8, 20, 2),
        windowEnd: DateTime.utc(2026, 8, 20, 4),
      );
      expect(body['asap'], isTrue);
      expect(body.containsKey('window_start'), isFalse);
      expect(body.containsKey('window_end'), isFalse);
    });

    test('windowed schedule sends UTC ISO-8601 window bounds', () {
      final body = buildScheduleBody(
        windowStart: DateTime.utc(2026, 8, 20, 2, 30),
        windowEnd: DateTime.utc(2026, 8, 20, 4, 30),
        note: 'change window',
      );
      expect(body['asap'], isFalse);
      expect(body['window_start'], '2026-08-20T02:30:00.000Z');
      expect(body['window_end'], '2026-08-20T04:30:00.000Z');
      expect(body['note'], 'change window');
    });

    test('unschedule uses a distinct body shape (built by the client method,'
        ' not this helper)', () {
      // unscheduleChange() sends {unschedule: true, note} directly, never
      // through buildScheduleBody: guard that assumption by asserting the
      // schedule body never carries an "unschedule" key.
      final body = buildScheduleBody(asap: true);
      expect(body.containsKey('unschedule'), isFalse);
    });
  });

  group('KanbanCard.fromJson change fields + chips', () {
    test('parses itil_status/prepared_pr/prepared_by/validation/'
        'scheduled_window/chips on a change card', () {
      final card = KanbanCard.fromJson({
        'id': 'chg-42',
        'kind': 'change',
        'title': 'Roll out the new gate',
        'status': 'ready',
        'swimlane': 'change',
        'itil_status': 'reviewing',
        'prepared_pr': {'url': 'https://example/pr/1', 'branch': 'chg-42'},
        'prepared_by': 'lumina',
        'validation': {'passed': true, 'checks': []},
        'scheduled_window': null,
        'chips': {
          'cab': {
            'approved': 2,
            'rejected': 0,
            'abstain': 1,
            'human_decision': 'approved',
          },
          'validation': {'passed': true, 'check_count': 5, 'stale': false},
          'window': {'label': 'ASAP', 'asap': true},
        },
      });

      expect(card.isChange, isTrue);
      expect(card.itilStatus, 'reviewing');
      expect(card.preparedPr?['url'], 'https://example/pr/1');
      expect(card.preparedBy, 'lumina');
      expect(card.validation?['passed'], true);
      expect(card.scheduledWindow, isNull);

      final chips = card.chips!;
      expect(chips.cab.approved, 2);
      expect(chips.cab.rejected, 0);
      expect(chips.cab.abstain, 1);
      expect(chips.cab.humanDecision, 'approved');
      expect(chips.validation?.passed, isTrue);
      expect(chips.validation?.checkCount, 5);
      expect(chips.validation?.stale, isFalse);
      expect(chips.window.label, 'ASAP');
      expect(chips.window.asap, isTrue);
    });

    test('a non-change card carries no change fields', () {
      final card = KanbanCard.fromJson({
        'id': 'task-7',
        'kind': 'task',
        'title': 'Fix the thing',
        'status': 'doing',
        'swimlane': 'feature',
      });

      expect(card.isChange, isFalse);
      expect(card.itilStatus, isNull);
      expect(card.preparedPr, isNull);
      expect(card.validation, isNull);
      expect(card.scheduledWindow, isNull);
      expect(card.chips, isNull);
    });

    test('isChange is true for a chg- id even without an explicit kind '
        '(defensive, matches design doc: "id starts with chg-, or kind == '
        'change")', () {
      final card = KanbanCard.fromJson({
        'id': 'chg-99',
        'title': 'Emergency patch',
        'status': 'backlog',
        'swimlane': 'change',
      });
      expect(card.isChange, isTrue);
    });

    test('validation chip is null when the change has never been validated',
        () {
      final card = KanbanCard.fromJson({
        'id': 'chg-1',
        'kind': 'change',
        'title': 'x',
        'status': 'backlog',
        'swimlane': 'change',
        'chips': {
          'cab': {'approved': 0, 'rejected': 0, 'abstain': 0},
          'window': {'label': 'none', 'asap': false},
        },
      });
      expect(card.chips?.validation, isNull);
    });

    test('parses pir_note once the change is verified (CM P3.3)', () {
      final card = KanbanCard.fromJson({
        'id': 'chg-42',
        'kind': 'change',
        'title': 'Roll out the new gate',
        'status': 'done',
        'swimlane': 'change',
        'itil_status': 'verified',
        'pir_note': 'Deployed clean, no rollback needed.',
      });
      expect(card.itilStatus, 'verified');
      expect(card.pirNote, 'Deployed clean, no rollback needed.');
    });

    test('pir_note is null before the change is verified', () {
      final card = KanbanCard.fromJson({
        'id': 'chg-42',
        'kind': 'change',
        'title': 'Roll out the new gate',
        'status': 'doing',
        'swimlane': 'change',
        'itil_status': 'deployed',
      });
      expect(card.pirNote, isNull);
    });
  });
}
