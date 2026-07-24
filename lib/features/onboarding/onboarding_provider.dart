import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Hive box + key that persist "onboarding has been completed" so the wizard
/// runs at most once per device. Pre-opened in `main()` (wrapped in try/catch)
/// so a corrupt/locked box never bricks launch.
const kOnboardingBox = 'onboarding';
const _kIsCompleteKey = 'isComplete';

/// Total number of onboarding pages, in order:
///   welcome -> server URL -> identity (device-key enrollment) -> done.
const kOnboardingPageCount = 4;

/// State for the first-run onboarding wizard.
///
/// Modernized to the CURRENT model (server picker + device-key enrollment):
/// the legacy PGP-choice / localhost transport-probe fields were removed along
/// with the stale identity/transport/pair pages they backed.
class OnboardingState {
  const OnboardingState({
    this.currentStep = 0,
    this.isComplete = false,
  });

  final int currentStep;
  final bool isComplete;

  OnboardingState copyWith({
    int? currentStep,
    bool? isComplete,
  }) {
    return OnboardingState(
      currentStep: currentStep ?? this.currentStep,
      isComplete: isComplete ?? this.isComplete,
    );
  }
}

/// Notifier for the onboarding wizard. Persists [isComplete] to Hive so the
/// wizard only runs once per device.
class OnboardingNotifier extends Notifier<OnboardingState> {
  @override
  OnboardingState build() {
    Future.microtask(_loadPersistedState);
    return const OnboardingState();
  }

  Future<void> _loadPersistedState() async {
    try {
      final box = await Hive.openBox<dynamic>(kOnboardingBox);
      final isComplete = box.get(_kIsCompleteKey, defaultValue: false) as bool;
      if (isComplete != state.isComplete) {
        state = state.copyWith(isComplete: isComplete);
      }
    } catch (_) {
      // Corrupt/locked box: fall through to defaults (treat as first run).
    }
  }

  /// Jump to a specific step (clamped to the valid page range).
  void goToStep(int step) {
    if (step >= 0 && step < kOnboardingPageCount) {
      state = state.copyWith(currentStep: step);
    }
  }

  /// Advance to the next page in the wizard.
  void nextStep() {
    final next = state.currentStep + 1;
    if (next < kOnboardingPageCount) {
      state = state.copyWith(currentStep: next);
    }
  }

  /// Mark the wizard as done. Updates in-memory state FIRST (so
  /// [onboardingCompleteProvider] fires immediately and the router's
  /// refreshListenable clears the first-run gate), then persists best-effort.
  Future<void> markComplete() async {
    state = state.copyWith(isComplete: true);
    try {
      final box = await Hive.openBox<dynamic>(kOnboardingBox);
      await box.put(_kIsCompleteKey, true);
    } catch (_) {
      // Best-effort persistence; in-memory state already updated.
    }
  }
}

final onboardingProvider =
    NotifierProvider<OnboardingNotifier, OnboardingState>(
  OnboardingNotifier.new,
);

/// Convenience provider, true once onboarding has been completed. The router
/// watches this (via its refreshListenable bridge) to gate first-run routing.
final onboardingCompleteProvider = Provider<bool>((ref) {
  return ref.watch(onboardingProvider).isComplete;
});
