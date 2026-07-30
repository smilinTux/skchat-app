import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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

  static const _tabs = <AppNavTab>[
    AppNavTab(
      label: 'Chats',
      icon: Icons.chat_bubble_outline_rounded,
      activeIcon: Icons.chat_bubble_rounded,
      path: AppRoutes.chats,
    ),
    AppNavTab(
      label: 'Spaces',
      icon: Icons.podcasts_outlined,
      activeIcon: Icons.podcasts_rounded,
      path: AppRoutes.spaces,
    ),
    AppNavTab(
      label: 'Activity',
      icon: Icons.notifications_outlined,
      activeIcon: Icons.notifications_rounded,
      path: AppRoutes.activity,
    ),
    // Ops hub, gateway to the operator control surfaces (Cluster, Coord,
    // Recordings, Conferences, Groups). Keeps the bottom bar at 5 items while
    // making every operator route reachable in <= 2 taps.
    AppNavTab(
      label: 'Ops',
      icon: Icons.grid_view_outlined,
      activeIcon: Icons.grid_view_rounded,
      path: AppRoutes.hub,
    ),
    AppNavTab(
      label: 'Me',
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      path: AppRoutes.profile,
    ),
  ];

  int _indexFor(BuildContext context, WidgetRef _) {
    final location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith(AppRoutes.spaces)) return 1;
    if (location.startsWith(AppRoutes.activity)) return 2;
    // "Ops" stays highlighted while on the hub or any operator surface it
    // gates (cluster / coord / recordings).
    if (location.startsWith(AppRoutes.hub) ||
        location.startsWith(AppRoutes.cluster) ||
        location.startsWith(AppRoutes.skmap) ||
        location.startsWith(AppRoutes.coord) ||
        location.startsWith(AppRoutes.recordings)) {
      return 3;
    }
    if (location.startsWith(AppRoutes.profile)) return 4;
    return 0; // chats
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = _indexFor(context, ref);
    final daemonState = ref.watch(skcommsSyncProvider);
    final isOffline = daemonState.status == DaemonStatus.offline;

    // Badge counts are derived from the SAME existing providers, so both the
    // bottom bar and the wide left rail render one model. Chats shows total
    // unread across conversations; Ops shows pending consent requests. Other
    // tabs carry no badge. The list aligns 1:1 with [_tabs].
    final unreadTotal = ref
        .watch(chatsProvider)
        .fold<int>(0, (sum, c) => sum + c.unreadCount);
    final pendingConsent = ref.watch(consentPendingCountProvider);
    final badgeCounts = <int>[
      unreadTotal, // Chats
      0, // Spaces
      0, // Activity
      pendingConsent, // Ops
      0, // Me
    ];

    return _IncomingCallPoller(
      child: PiPOverlay(
        child: AppShellScaffold(
          tabs: _tabs,
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
