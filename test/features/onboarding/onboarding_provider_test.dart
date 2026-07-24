import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/onboarding/onboarding_provider.dart';

void main() {
  group('OnboardingState', () {
    test('defaults are correct', () {
      const state = OnboardingState();

      expect(state.currentStep, 0);
      expect(state.isComplete, false);
    });

    test('copyWith updates only specified fields', () {
      const state = OnboardingState();

      final updated = state.copyWith(currentStep: 3);

      expect(updated.currentStep, 3);
      expect(updated.isComplete, false);
    });

    test('copyWith preserves all fields when none specified', () {
      const state = OnboardingState(currentStep: 2, isComplete: true);

      final updated = state.copyWith();

      expect(updated.currentStep, 2);
      expect(updated.isComplete, true);
    });

    test('copyWith sets completion', () {
      const state = OnboardingState();

      final updated = state.copyWith(isComplete: true);

      expect(updated.isComplete, true);
      expect(updated.currentStep, 0);
    });
  });

  group('kOnboardingPageCount', () {
    test('is 4 pages (welcome -> server -> identity -> done)', () {
      expect(kOnboardingPageCount, 4);
    });
  });

  group('Onboarding providers', () {
    test('providers are accessible', () {
      expect(onboardingProvider, isNotNull);
      expect(onboardingCompleteProvider, isNotNull);
    });
  });
}
