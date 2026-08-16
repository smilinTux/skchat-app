import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../deploy_freshness.dart";
import "../theme/theme.dart";
import "../../services/deploy_freshness_probe.dart";
import "../../services/deploy_freshness_service.dart";

/// Wraps the whole app (mounted in `main.dart`'s `MaterialApp.router.builder`,
/// above the router/navigator) and overlays a dismissible "a newer version is
/// running on the server" prompt when one is detected.
///
/// WHY a prompt and never an automatic reload: this app has no reliable, cheap
/// way to tell "the operator is genuinely idle" from "the operator is mid-call,
/// mid-Space, or mid-draft on some other screen" without reaching into screens
/// this change deliberately does not touch (`space_room_screen.dart`,
/// `call_shared/video/`, owned by another change in flight). Losing a live
/// room, or a half-typed message, to a surprise refresh is far worse than
/// running an old build for another minute, so this NEVER reloads on its own.
/// See `core/deploy_freshness.dart`: there is no "auto reload" action at all,
/// on purpose.
///
/// WHY `visibilitychange` and not a timer: polling is driven by
/// [WidgetsBindingObserver.didChangeAppLifecycleState] reaching
/// [AppLifecycleState.resumed], which on Flutter's web engine IS the DOM
/// `visibilitychange` event turning visible (`_BrowserAppLifecycleState` in
/// the engine listens to exactly that and re-fires `resumed`). That is when a
/// phone realistically returns to the app, and it costs nothing while the tab
/// is hidden, unlike a fast timer that would keep firing in a background tab.
/// One extra check also runs right after the first frame, to catch a tab that
/// was opened, left on the join screen, and never explicitly backgrounded.
class DeployFreshnessBanner extends ConsumerStatefulWidget {
  const DeployFreshnessBanner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DeployFreshnessBanner> createState() =>
      _DeployFreshnessBannerState();
}

class _DeployFreshnessBannerState extends ConsumerState<DeployFreshnessBanner>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Establish the session baseline shortly after launch, not just on the
    // first visibilitychange: a tab that is opened and simply left alone
    // (the "join card" case the old Space client handled) should still learn
    // what it is running.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(deployFreshnessProvider.notifier).checkNow());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(deployFreshnessProvider.notifier).checkNow());
    }
  }

  void _dismiss() {
    ref.read(deployFreshnessProvider.notifier).acknowledge();
  }

  void _reload() {
    // Acknowledge first: reloadPage() never returns on web (the tab is gone),
    // and on the stub it is a no-op, so this ordering costs nothing either way
    // while guaranteeing the tracker's state never outlives this decision.
    ref.read(deployFreshnessProvider.notifier).acknowledge();
    reloadPage();
  }

  @override
  Widget build(BuildContext context) {
    final action = ref.watch(deployFreshnessProvider);
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (action == DeployFreshnessAction.prompt)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _NewVersionBanner(
              key: const Key("deploy-freshness-banner"),
              onReload: _reload,
              onDismiss: _dismiss,
            ),
          ),
      ],
    );
  }
}

class _NewVersionBanner extends StatelessWidget {
  const _NewVersionBanner({
    super.key,
    required this.onReload,
    required this.onDismiss,
  });

  final VoidCallback onReload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final spacing = Theme.of(context).extension<SovereignSpacing>();
    final cardPad = spacing?.cardPad ?? 12.0;
    final gutter = spacing?.gutter ?? 12.0;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.all(gutter),
        child: Material(
          color: SovereignColors.surfaceRaised,
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.all(cardPad),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SovereignColors.accentWarning),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.system_update_alt,
                  color: SovereignColors.accentWarning,
                ),
                SizedBox(width: gutter),
                Expanded(
                  child: Text(
                    "A newer version is running on the server. "
                    "Reload to update.",
                    style: textTheme.bodyMedium,
                  ),
                ),
                TextButton(
                  key: const Key("deploy-freshness-reload"),
                  onPressed: onReload,
                  child: Text(
                    "Reload",
                    style: textTheme.labelLarge?.copyWith(
                      color: SovereignColors.accentWarning,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key("deploy-freshness-dismiss"),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close),
                  tooltip: "Dismiss",
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
