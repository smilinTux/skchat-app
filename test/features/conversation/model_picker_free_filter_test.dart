// Tests for the model picker's "Free only" filter + FREE badge.
//
// Covers two layers:
//   1. The pure [filterModelsByFree] predicate over a fake catalog.
//   2. The [ModelPickerModelsSection] widget: FREE badge renders for a free
//      model, and toggling "Free only" narrows the list to free models.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/conversation/widgets/model_picker_button.dart';
import 'package:skchat/services/agent_model_service.dart';

const _fakeModels = <AgentModel>[
  AgentModel(id: 'nvidia/free-a', provider: 'nvidia', free: true),
  AgentModel(id: 'openrouter/free-b', provider: 'openrouter', free: true),
  AgentModel(id: 'anthropic/claude-opus', provider: 'anthropic', free: false),
];

void main() {
  group('filterModelsByFree', () {
    test('returns all models when freeOnly is off', () {
      final out = filterModelsByFree(_fakeModels, freeOnly: false);
      expect(out, hasLength(3));
    });

    test('returns only free-flagged models when freeOnly is on', () {
      final out = filterModelsByFree(_fakeModels, freeOnly: true);
      expect(out, hasLength(2));
      expect(out.every((m) => m.free == true), isTrue);
      expect(out.map((m) => m.id), containsAll(<String>[
        'nvidia/free-a',
        'openrouter/free-b',
      ]));
    });

    test('treats a null free flag as not free', () {
      const models = [AgentModel(id: 'x', provider: 'p', free: null)];
      expect(filterModelsByFree(models, freeOnly: true), isEmpty);
    });
  });

  group('AgentModel.fromJson provider fallback', () {
    test('falls back to owned_by when provider is absent', () {
      final m = AgentModel.fromJson({
        'id': 'nvidia/foo',
        'owned_by': 'nvidia',
        'free': true,
      });
      expect(m.provider, 'nvidia');
      expect(m.free, isTrue);
    });

    test('prefers provider over owned_by when both present', () {
      final m = AgentModel.fromJson({
        'id': 'x',
        'provider': 'openrouter',
        'owned_by': 'ignored',
      });
      expect(m.provider, 'openrouter');
    });
  });

  Widget harness() => MaterialApp(
        home: Scaffold(
          body: ModelPickerModelsSection(
            models: _fakeModels,
            selection: 'anthropic/claude-opus',
            onSelect: (_) {},
          ),
        ),
      );

  group('ModelPickerModelsSection widget', () {
    testWidgets('renders a FREE badge for each free model', (tester) async {
      await tester.pumpWidget(harness());
      // Two free models in the fake catalog, so two FREE badges.
      expect(find.text('FREE'), findsNWidgets(2));
      // All three rows visible with the filter off.
      expect(find.byType(ListTile), findsNWidgets(3));
    });

    testWidgets('Free only toggle shows only free models', (tester) async {
      await tester.pumpWidget(harness());
      expect(find.byType(ListTile), findsNWidgets(3));

      await tester.tap(find.widgetWithText(FilterChip, 'Free only'));
      await tester.pumpAndSettle();

      // Paid model gone, only the two free rows remain.
      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.text('anthropic/claude-opus'), findsNothing);
      expect(find.text('nvidia/free-a'), findsOneWidget);
      expect(find.text('openrouter/free-b'), findsOneWidget);
    });
  });
}
