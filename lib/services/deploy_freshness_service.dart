/// Wiring for `core/deploy_freshness.dart`'s pure decision: fetches the
/// server's current build marker (see `deploy_freshness_probe.dart`) and
/// feeds it to a [DeployFreshnessTracker], exposed as Riverpod state so
/// `DeployFreshnessBanner` can watch it.
///
/// This is the ONLY layer that knows about HTTP or Riverpod; the decision
/// itself is entirely in the pure module, unit tested there without any of
/// this.
library;

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/build_info.dart";
import "../core/deploy_freshness.dart";
import "deploy_freshness_probe.dart";

class DeployFreshnessNotifier extends Notifier<DeployFreshnessAction> {
  DeployFreshnessTracker? _tracker;

  // Reentrancy guard: a slow check still in flight when another
  // visibilitychange fires (e.g. a flaky connection) must not race a second
  // fetch against the tracker's baseline/pending state.
  bool _checking = false;

  @override
  DeployFreshnessAction build() {
    _tracker = DeployFreshnessTracker(myBuildId: kBuildId);
    return DeployFreshnessAction.none;
  }

  /// Run one check. Safe to call as often as you like (e.g. every
  /// `visibilitychange`); overlapping calls collapse to the one already in
  /// flight rather than racing, and any failure inside the probe already
  /// resolves to `null` (see `deploy_freshness_probe.dart`), so this never
  /// throws and never blocks the caller on a stuck network.
  Future<void> checkNow() async {
    final tracker = _tracker;
    if (tracker == null || _checking) return;
    _checking = true;
    try {
      final marker = await fetchServedBuildMarker();
      state = tracker.onCheck(marker);
    } finally {
      _checking = false;
    }
  }

  /// The operator dismissed the prompt, or tapped reload (the page is about
  /// to leave anyway). Either way this deploy is now "known", so it will not
  /// prompt again; a genuinely newer one still will.
  void acknowledge() {
    _tracker?.acknowledge();
    state = DeployFreshnessAction.none;
  }
}

final deployFreshnessProvider =
    NotifierProvider<DeployFreshnessNotifier, DeployFreshnessAction>(
        DeployFreshnessNotifier.new);
