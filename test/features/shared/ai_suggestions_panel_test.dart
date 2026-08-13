import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/features/shared/ai_suggestions_panel.dart';
import 'package:skchat/services/skcapstone_client.dart';

class MockSKCapstoneClient extends Mock implements SKCapstoneClient {}

void main() {
  setUpAll(() {
    registerFallbackValue('');
  });

  Future<void> pump(WidgetTester tester, SKCapstoneClient client) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          skCapstoneClientProvider.overrideWithValue(client),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AiSuggestionsPanel(cardId: 'card-1', footnote: 'a footnote'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders the initial "Suggest next steps" button', (tester) async {
    final client = MockSKCapstoneClient();
    await pump(tester, client);

    expect(find.text('NEXT STEPS (AI)'), findsOneWidget);
    expect(find.text('Suggest next steps'), findsOneWidget);
    expect(find.text('a footnote'), findsOneWidget);
    // Nothing was fetched yet: no suggestion tiles, no queue button.
    expect(find.text('Queue'), findsNothing);
    verifyNever(() => client.getCardSuggestions(any()));
  });

  testWidgets('fetches and renders suggestions on tap, then queues one',
      (tester) async {
    final client = MockSKCapstoneClient();
    when(() => client.getCardSuggestions(any())).thenAnswer(
      (_) async => const [
        CardSuggestion(text: 'Do the thing', mode: 'propose'),
      ],
    );
    when(() => client.queueAi(
          any(),
          instruction: any(named: 'instruction'),
          mode: any(named: 'mode'),
        )).thenAnswer((_) async => 'run-123');

    await pump(tester, client);

    await tester.tap(find.text('Suggest next steps'));
    await tester.pump();

    expect(find.text('Do the thing'), findsOneWidget);
    expect(find.text('propose'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Re-suggest'), findsOneWidget);

    await tester.tap(find.text('Queue'));
    await tester.pump();

    verify(() => client.queueAi(
          'card-1',
          instruction: 'Do the thing',
          mode: 'propose',
        )).called(1);
  });

  Future<void> pumpChange(
    WidgetTester tester,
    SKCapstoneClient client, {
    String? changeItilStatus,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          skCapstoneClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AiSuggestionsPanel(
              cardId: 'chg-1',
              isChangeCard: true,
              changeItilStatus: changeItilStatus,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
      'change card: mode chips relabel Propose/Dry-run/Prepare, Prepare '
      'enabled while proposed', (tester) async {
    final client = MockSKCapstoneClient();
    when(() => client.getCardSuggestions(any())).thenAnswer(
      (_) async => const [
        CardSuggestion(text: 'Assess the risk', mode: 'propose'),
        CardSuggestion(text: 'Dry-run the migration', mode: 'dry-run'),
        CardSuggestion(text: 'Draft the change', mode: 'execute'),
      ],
    );
    when(() => client.queueAi(
          any(),
          instruction: any(named: 'instruction'),
          mode: any(named: 'mode'),
        )).thenAnswer((_) async => 'run-999');

    await pumpChange(tester, client, changeItilStatus: 'proposed');

    await tester.tap(find.text('Suggest next steps'));
    await tester.pump();

    // Raw wire mode text never appears on a change card: it's relabeled.
    expect(find.text('propose'), findsNothing);
    expect(find.text('execute'), findsNothing);
    expect(find.text('Propose'), findsOneWidget);
    expect(find.text('Dry-run'), findsOneWidget);
    expect(find.text('Prepare'), findsOneWidget);
    // proposed is inside the draft window: Prepare's Queue stays enabled and
    // the blocked-execute explanation is not shown.
    expect(find.text(kChangeExecuteBlockedReason), findsNothing);
    final queueButtons = tester.widgetList<FilledButton>(
      find.widgetWithText(FilledButton, 'Queue'),
    );
    expect(queueButtons.every((b) => b.onPressed != null), isTrue);
  });

  testWidgets(
      'change card: Prepare is blocked outside proposed/reviewing, reason '
      'shown verbatim and Queue disabled', (tester) async {
    final client = MockSKCapstoneClient();
    when(() => client.getCardSuggestions(any())).thenAnswer(
      (_) async => const [
        CardSuggestion(text: 'Draft the change', mode: 'execute'),
      ],
    );

    await pumpChange(tester, client, changeItilStatus: 'approved');

    await tester.tap(find.text('Suggest next steps'));
    await tester.pump();

    expect(find.text('Prepare'), findsOneWidget);
    expect(find.text(kChangeExecuteBlockedReason), findsOneWidget);
    final queueButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Queue'),
    );
    expect(queueButton.onPressed, isNull);

    // Tapping a disabled button is a no-op; nothing should be queued.
    await tester.tap(find.widgetWithText(FilledButton, 'Queue'), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => client.queueAi(
          any(),
          instruction: any(named: 'instruction'),
          mode: any(named: 'mode'),
        ));
  });

  testWidgets('non-change card keeps the raw lowercase mode text (unaffected)',
      (tester) async {
    final client = MockSKCapstoneClient();
    when(() => client.getCardSuggestions(any())).thenAnswer(
      (_) async => const [
        CardSuggestion(text: 'Implement it', mode: 'execute'),
      ],
    );

    await pump(tester, client); // isChangeCard defaults to false

    await tester.tap(find.text('Suggest next steps'));
    await tester.pump();

    expect(find.text('execute'), findsOneWidget);
    expect(find.text('Prepare'), findsNothing);
    final queueButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Queue'),
    );
    expect(queueButton.onPressed, isNotNull);
  });
}
