import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/modules/module_manifest.dart';
import '../../core/modules/module_registry.dart';
import '../../core/router/app_router.dart';
import '../../features/calls/incoming_call_watcher.dart';
import '../../features/calls/widgets/incoming_call_banner.dart';
import '../../features/calls/widgets/pip_overlay.dart';
import '../../features/chats/chats_provider.dart';
import '../../services/consent_service.dart';
import '../../services/skcomms_sync.dart';
import 'app_shell_scaffold.dart';

/// How often [_IncomingCallPoller] calls [IncomingCallWatcher.pollOnce] while
/// the shell is mounted (foreground only; no background/isolate polling).
const _incomingCallPollInterval = Duration(seconds: 4);

/// Thin `ConsumerStatefulWidget` wrapper that owns the foreground poll
/// [Timer] for incoming calls. A stateless `ref.listen` cannot start/cancel a
/// periodic timer tied to the widget lifecycle, so this small wrapper holds
/// it: started in [initState], cancelled in [dispose]. Renders [child]
/// unchanged, so it adds no visual footprint to [AppShell].
class _IncomingCallPoller extends ConsumerStatefulWidget {
  const _IncomingCallPoller({required this.child});

  final Widget child;

  @override
  ConsumerState<_IncomingCallPoller> createState() => _IncomingCallPollerState();
}

class _IncomingCallPollerState extends ConsumerState<_IncomingCallPoller> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_incomingCallPollInterval, (_) {
      ref.read(incomingCallWatcherProvider).pollOnce();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// AppShell wraps all main tab screens with the Sovereign Glass bottom nav bar.
/// Shows a subtle offline banner when the SKComms daemon is unreachable.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  /// The operator "Ops" hub is a gateway to the operator control surfaces
  /// (Cluster, Coord, Recordings, SkMap), not a registry subapp module, so it
  /// is inserted as a fixed destination just before "Me". It stays highlighted
  /// while on the hub or any surface it gates.
  static const _opsTab = AppNavTab(
    label: 'Ops',
    icon: Icons.grid_view_outlined,
    activeIcon: Icons.grid_view_rounded,
    path: AppRoutes.hub,
  );

  static bool _isOpsLocation(String location) =>
      location.startsWith(AppRoutes.hub) ||
      location.startsWith(AppRoutes.cluster) ||
      location.startsWith(AppRoutes.skmap) ||
      location.startsWith(AppRoutes.coord) ||
      location.startsWith(AppRoutes.recordings);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final daemonState = ref.watch(skcommsSyncProvider);
    final isOffline = daemonState.status == DaemonStatus.offline;

    // The primary destinations are derived from the module registry: every
    // nav-placed subapp module becomes a tab, in manifest order, with the
    // special Ops hub inserted before "Me". This is the R4.1 nav migration:
    // the registry is the source of truth and the shell renders from it
    // instead of a hand-maintained const list. We read the raw registry (the
    // const manifest list), NOT capability/availability or per-user placement
    // prefs, so the core nav is always present and deterministic, exactly as
    // the old static tab list was, and a newly-added module (skcode) shows for
    // every user. Wiring capability-gating and the user's nav placement prefs
    // into the primary nav is a follow-up (the latter needs a prefs
    // seed-version migration so new modules default-on without re-enabling ones
    // the user disabled).
    final navModules = ref
        .watch(moduleRegistryProvider)
        .where((m) => m.defaultPlacement == ModulePlacement.nav)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    // Badge counts come from the SAME providers as before, so both the bottom
    // bar and the wide left rail render one model. Chats shows total unread;
    // Ops shows pending consent. Every list stays aligned 1:1 with [tabs].
    final unreadTotal = ref
        .watch(chatsProvider)
        .fold<int>(0, (sum, c) => sum + c.unreadCount);
    final pendingConsent = ref.watch(consentPendingCountProvider);

    final tabs = <AppNavTab>[];
    final badgeCounts = <int>[];
    var opsInserted = false;
    void addOps() {
      tabs.add(_opsTab);
      badgeCounts.add(pendingConsent);
      opsInserted = true;
    }

    for (final m in navModules) {
      if (!opsInserted && m.id == 'profile') addOps();
      tabs.add(AppNavTab(
        label: m.title,
        icon: m.icon,
        activeIcon: m.effectiveActiveIcon,
        path: m.route,
      ));
      badgeCounts.add(m.id == 'chats' ? unreadTotal : 0);
    }
    if (!opsInserted) addOps(); // no profile module (defensive): Ops goes last.

    final location = GoRouterState.of(context).matchedLocation;
    var currentIndex = 0;
    for (var i = 0; i < tabs.length; i++) {
      final path = tabs[i].path;
      if (path == AppRoutes.hub) {
        if (_isOpsLocation(location)) {
          currentIndex = i;
          break;
        }
      } else if (location.startsWith(path)) {
        currentIndex = i;
        break;
      }
    }

    return _IncomingCallPoller(
      child: PiPOverlay(
        child: AppShellScaffold(
          tabs: tabs,
          currentIndex: currentIndex,
          isOffline: isOffline,
          badgeCounts: badgeCounts,
          onSelect: context.go,
          banner: const IncomingCallBanner(),
          child: child,
        ),
      ),
    );
  }
}
