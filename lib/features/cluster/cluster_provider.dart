import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/cluster_service.dart';

/// Default cluster name skbloom uses everywhere (its `serve` default).
const kDefaultClusterName = 'skbloom';

/// Aggregated snapshot of the cluster control plane: the deployable service
/// catalog, the installed stacks, and live per-service readiness. Fetched
/// together so the screen renders a single coherent view.
class ClusterOverview {
  const ClusterOverview({
    required this.services,
    required this.stacks,
    required this.health,
  });

  final List<ClusterServiceDef> services;
  final List<ClusterStack> stacks;
  final List<ServiceHealth> health;

  /// Health row for a service namespace, if the live cluster reported one.
  ServiceHealth? healthFor(String name) {
    for (final h in health) {
      if (h.name == name) return h;
    }
    return null;
  }
}

/// Loads (and re-loads) the cluster overview from skbloom's JSON API.
///
/// Null is never returned — instead a failed load surfaces as
/// [AsyncError] so the screen can show an offline state with the base URL.
class ClusterOverviewNotifier extends AsyncNotifier<ClusterOverview> {
  @override
  Future<ClusterOverview> build() => _fetch();

  Future<ClusterOverview> _fetch() async {
    final svc = ref.read(clusterServiceProvider);
    // /api/services and /api/status are always available; /api/health is
    // fail-soft (returns [] without a live cluster) so it never blocks load.
    final services = await svc.listServices();
    final stacks = await svc.status();
    List<ServiceHealth> health = const [];
    try {
      health = await svc.health(cluster: kDefaultClusterName);
    } catch (_) {
      // No live cluster reachable — leave health empty.
    }
    return ClusterOverview(
      services: services,
      stacks: stacks,
      health: health,
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

final clusterOverviewProvider =
    AsyncNotifierProvider<ClusterOverviewNotifier, ClusterOverview>(
  ClusterOverviewNotifier.new,
);

/// Live state of an in-flight `/api/up` install (or a one-shot proposal).
class InstallState {
  const InstallState({
    this.proposal,
    this.events = const [],
    this.running = false,
    this.done = false,
    this.error,
  });

  /// The concierge proposal awaiting confirmation (null once `up` starts).
  final ClusterProposal? proposal;

  /// SSE step events received so far.
  final List<UpEvent> events;

  /// True while the `/api/up` stream is open.
  final bool running;

  /// True once the stream has completed.
  final bool done;

  /// A transport/error message, if any.
  final String? error;

  InstallState copyWith({
    ClusterProposal? proposal,
    bool clearProposal = false,
    List<UpEvent>? events,
    bool? running,
    bool? done,
    String? error,
    bool clearError = false,
  }) =>
      InstallState(
        proposal: clearProposal ? null : (proposal ?? this.proposal),
        events: events ?? this.events,
        running: running ?? this.running,
        done: done ?? this.done,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Drives the propose → confirm → `up` (SSE) install lifecycle for one intent.
class InstallNotifier extends Notifier<InstallState> {
  StreamSubscription<UpEvent>? _sub;

  @override
  InstallState build() {
    ref.onDispose(() => _sub?.cancel());
    return const InstallState();
  }

  /// Ask the concierge for a plan for [intent]; stash the proposal.
  Future<void> propose(String intent) async {
    state = const InstallState();
    try {
      final p = await ref.read(clusterServiceProvider).propose(intent);
      state = InstallState(proposal: p);
    } catch (e) {
      state = InstallState(error: e.toString());
    }
  }

  /// Confirm the current proposal and stream the install via `/api/up`.
  Future<void> confirmAndUp({bool tls = false}) async {
    final p = state.proposal;
    if (p == null || p.services.isEmpty) return;
    await _runUp(p.toProfile(tls: tls));
  }

  /// Stream an install for an explicit [profile] (skipping propose).
  Future<void> up(ClusterProfile profile) => _runUp(profile);

  Future<void> _runUp(ClusterProfile profile) async {
    await _sub?.cancel();
    state = state.copyWith(
      running: true,
      done: false,
      events: const [],
      clearError: true,
    );
    final svc = ref.read(clusterServiceProvider);
    _sub = svc.up(profile).listen(
      (ev) {
        state = state.copyWith(events: [...state.events, ev]);
      },
      onError: (Object e) {
        state = state.copyWith(running: false, error: e.toString());
      },
      onDone: () {
        state = state.copyWith(running: false, done: true);
        // Refresh the overview so the new stack shows up.
        ref.read(clusterOverviewProvider.notifier).refresh();
      },
      cancelOnError: true,
    );
  }

  /// Clear the install panel.
  void reset() {
    _sub?.cancel();
    state = const InstallState();
  }
}

final installProvider =
    NotifierProvider<InstallNotifier, InstallState>(InstallNotifier.new);
