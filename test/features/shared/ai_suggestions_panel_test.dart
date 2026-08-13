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
}
