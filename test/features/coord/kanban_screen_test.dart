import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/features/coord/kanban_screen.dart';
import 'package:skchat/services/skcapstone_client.dart';

/// CM P2.5: kanban card popout change-management section (CAB/validation/
/// window chips + Validate/Schedule/Arm). Same mocktail-on-SKCapstoneClient
/// pattern as ai_suggestions_panel_test.dart, one level up: these tests drive
/// the whole KanbanScreen so the popout is opened the same way a user opens
/// it (tap a card tile).
class MockSKCapstoneClient extends Mock implements SKCapstoneClient {}

const _changeChips = {
  'cab': {'approved': 2, 'rejected': 0, 'abstain': 1, 'human_decision': 'approved'},
  'validation': {'passed': true, 'check_count': 5, 'stale': false},
  'window': {'label': 'ASAP', 'asap': true},
};

KanbanCard _changeCard({String itilStatus = 'reviewing', Map<String, dynamic>? chips}) =>
    KanbanCard.fromJson({
      'id': 'chg-42',
      'kind': 'change',
      'title': 'Roll out the new gate',
      'status': 'ready',
      'swimlane': 'change',
      'itil_status': itilStatus,
      'chips': chips ?? _changeChips,
    });

KanbanCard _taskCard() => KanbanCard.fromJson({
      'id': 'task-7',
      'kind': 'task',
      'title': 'Fix the flaky test',
      'status': 'doing',
      'swimlane': 'feature',
    });

void main() {
  setUpAll(() {
    registerFallbackValue(const ChangeActionResult(ok: true));
  });

  Future<void> pumpBoard(
    WidgetTester tester,
    SKCapstoneClient client,
    KanbanBoard board,
  ) async {
    when(() => client.getKanban()).thenAnswer((_) async => board);
    when(() => client.getCardSuggestions(any())).thenAnswer((_) async => const []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [skCapstoneClientProvider.overrideWithValue(client)],
        child: const MaterialApp(home: KanbanScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'change card popout shows the CAB/validation/window chips and '
      'Validate/Schedule, but hides Arm while not scheduled', (tester) async {
    final client = MockSKCapstoneClient();
    final card = _changeCard(itilStatus: 'reviewing');
    await pumpBoard(
      tester,
      client,
      KanbanBoard(columns: const ['backlog', 'ready', 'doing', 'review', 'done'], cards: [card]),
    );

    await tester.tap(find.text('Roll out the new gate'));
    await tester.pumpAndSettle();

    expect(find.text('CHANGE MANAGEMENT'), findsOneWidget);
    // CAB tally + human decision marker.
    expect(find.textContaining('2A/0R/1Ab'), findsOneWidget);
    expect(find.textContaining('human: approved'), findsOneWidget);
    // Validation verdict chip.
    expect(find.textContaining('PASS'), findsOneWidget);
    expect(find.textContaining('5 checks'), findsOneWidget);
    // Window chip.
    expect(find.text('ASAP'), findsOneWidget);
    // The itil_status chip itself.
    expect(find.text('reviewing'), findsOneWidget);

    expect(find.widgetWithText(OutlinedButton, 'Validate'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Schedule'), findsOneWidget);
    expect(find.text('Arm deploy'), findsNothing);
    expect(find.text('Unschedule'), findsNothing);
  });

  testWidgets('Arm deploy is visible only once the change is scheduled',
      (tester) async {
    final client = MockSKCapstoneClient();
    final card = _changeCard(itilStatus: 'scheduled');
    await pumpBoard(
      tester,
      client,
      KanbanBoard(columns: const ['backlog', 'ready', 'doing', 'review', 'done'], cards: [card]),
    );

    await tester.tap(find.text('Roll out the new gate'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Arm deploy'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Unschedule'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Reschedule'), findsOneWidget);
  });

  testWidgets('Validate posts to validateChange and shows the verdict',
      (tester) async {
    final client = MockSKCapstoneClient();
    final card = _changeCard(itilStatus: 'proposed');
    when(() => client.validateChange('chg-42')).thenAnswer(
      (_) async => const ChangeActionResult(
        ok: true,
        data: {
          'validated': true,
          'validation': {'passed': false},
        },
      ),
    );
    await pumpBoard(
      tester,
      client,
      KanbanBoard(columns: const ['backlog', 'ready', 'doing', 'review', 'done'], cards: [card]),
    );

    await tester.tap(find.text('Roll out the new gate'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Validate'));
    await tester.pumpAndSettle();

    verify(() => client.validateChange('chg-42')).called(1);
    expect(find.text('Validation FAILED'), findsOneWidget);
  });

  testWidgets(
      'Schedule sheet shows deploy_mode locked to confirm; ASAP submits '
      'asap:true with no window bounds', (tester) async {
    final client = MockSKCapstoneClient();
    final card = KanbanCard.fromJson({
      'id': 'chg-42',
      'kind': 'change',
      'title': 'Roll out the new gate',
      'status': 'ready',
      'swimlane': 'change',
      'itil_status': 'approved',
    });
    when(() => client.scheduleChange(
          'chg-42',
          windowStart: any(named: 'windowStart'),
          windowEnd: any(named: 'windowEnd'),
          asap: any(named: 'asap'),
          note: any(named: 'note'),
        )).thenAnswer((_) async => const ChangeActionResult(ok: true));
    await pumpBoard(
      tester,
      client,
      KanbanBoard(columns: const ['backlog', 'ready', 'doing', 'review', 'done'], cards: [card]),
    );

    await tester.tap(find.text('Roll out the new gate'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Schedule'));
    await tester.pumpAndSettle();

    // deploy_mode is VISIBLE but LOCKED: no control to change it away from
    // "confirm" anywhere in the sheet.
    expect(find.text('confirm (locked)'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Schedule'));
    await tester.pumpAndSettle();

    verify(() => client.scheduleChange(
          'chg-42',
          windowStart: null,
          windowEnd: null,
          asap: true,
          note: '',
        )).called(1);
  });

  testWidgets('non-change card is unaffected: no CHANGE MANAGEMENT section',
      (tester) async {
    final client = MockSKCapstoneClient();
    final card = _taskCard();
    await pumpBoard(
      tester,
      client,
      KanbanBoard(columns: const ['backlog', 'ready', 'doing', 'review', 'done'], cards: [card]),
    );

    await tester.tap(find.text('Fix the flaky test'));
    await tester.pumpAndSettle();

    expect(find.text('CHANGE MANAGEMENT'), findsNothing);
    expect(find.text('Validate'), findsNothing);
    expect(find.text('Schedule'), findsNothing);
    expect(find.text('Arm deploy'), findsNothing);
  });
}
