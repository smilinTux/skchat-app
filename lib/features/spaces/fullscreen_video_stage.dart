import "package:flutter/foundation.dart" show ValueListenable;
import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../core/theme/sovereign_colors.dart";

/// Wraps a video widget (e.g. a screen-share [VideoTrackRenderer]) with a
/// fullscreen toggle: an overlay button on the tile, double-tap to enter
/// fullscreen, and a black immersive route with an exit control + Esc
/// support to leave it.
///
/// Fullscreen is implemented as a plain route push onto the ROOT navigator
/// (so it covers the whole window, not just the Space room's own nested
/// stack), keeping the underlying call/audio session completely untouched.
///
/// Track re-publish survives gracefully: [video] and [overlay] are pushed
/// through a [ValueNotifier] that is updated on every rebuild, so if the
/// live [VideoTrack] is swapped (re-publish) while fullscreen is open, the
/// fullscreen page picks up the new track without dropping out.
///
/// Auto-exit: if this widget is removed from the tree while fullscreen is
/// active (the share it renders has ended, so the caller stops building it),
/// [dispose] pops the fullscreen route so the viewer is not left staring at
/// a stale black screen.
class FullscreenableVideo extends StatefulWidget {
  const FullscreenableVideo({
    super.key,
    required this.video,
    this.overlay,
    this.aspectRatio = 16 / 9,
    this.borderRadius = 14,
    this.semanticsLabel,
  });

  /// The bare video content, e.g. `VideoTrackRenderer(track)`. Rendered as-is
  /// in both inline and fullscreen presentations.
  final Widget video;

  /// Optional content drawn on top of the video in both modes (e.g. a
  /// "Streaming: name" label pill). Positioned by the caller.
  final Widget? overlay;

  final double aspectRatio;
  final double borderRadius;
  final String? semanticsLabel;

  @override
  State<FullscreenableVideo> createState() => _FullscreenableVideoState();
}

class _FullscreenableVideoState extends State<FullscreenableVideo> {
  bool _hovering = false;
  bool _fullscreenActive = false;
  Route<void>? _route;
  late final ValueNotifier<Widget> _videoNotifier;
  late final ValueNotifier<Widget?> _overlayNotifier;

  @override
  void initState() {
    super.initState();
    _videoNotifier = ValueNotifier(widget.video);
    _overlayNotifier = ValueNotifier(widget.overlay);
  }

  @override
  void didUpdateWidget(FullscreenableVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep any open fullscreen page in sync with a re-published track
    // instead of leaving it pinned to a stale frame. Deferred to a
    // post-frame callback: the fullscreen page's ValueListenableBuilder
    // lives in a SIBLING Overlay route (not a descendant of this widget),
    // so notifying it synchronously mid-build (this runs inside
    // didUpdateWidget, itself mid-build) trips Flutter's "setState during
    // build" guard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _videoNotifier.value = widget.video;
      _overlayNotifier.value = widget.overlay;
    });
  }

  @override
  void dispose() {
    // The share this tile renders has gone away (caller stopped building
    // us), so if fullscreen is still open, close it rather than leaving a
    // dangling black route on top of the (now video-less) room.
    final route = _route;
    if (_fullscreenActive && route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
    _videoNotifier.dispose();
    _overlayNotifier.dispose();
    super.dispose();
  }

  Future<void> _enterFullscreen() async {
    if (_fullscreenActive) return;
    setState(() => _fullscreenActive = true);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = PageRouteBuilder<void>(
      opaque: true,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (routeContext, animation, secondaryAnimation) {
        return FadeTransition(
          opacity: animation,
          child: _FullscreenVideoPage(
            videoListenable: _videoNotifier,
            overlayListenable: _overlayNotifier,
            aspectRatio: widget.aspectRatio,
            onExit: () {
              if (Navigator.of(routeContext).canPop()) {
                Navigator.of(routeContext).pop();
              }
            },
          ),
        );
      },
    );
    _route = route;
    await navigator.push(route);
    // Route popped, whether via exit button, Esc, double-tap, or the
    // dispose()-driven auto-exit above.
    _route = null;
    if (mounted) {
      setState(() => _fullscreenActive = false);
    } else {
      _fullscreenActive = false;
    }
  }

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    // The double-tap-to-fullscreen gesture wraps ONLY the video surface, not
    // the overlay button below: keeping the button OUTSIDE that detector
    // (a later Stack sibling, not a descendant) means a plain tap on the
    // button resolves immediately instead of waiting out the gesture
    // arena's double-tap window.
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setHovering(!_hovering),
              onDoubleTap: _enterFullscreen,
              child: Container(color: Colors.black, child: widget.video),
            ),
            if (widget.overlay != null) widget.overlay!,
            Positioned(
              right: 8,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: _hovering ? 1.0 : 0.55,
                duration: const Duration(milliseconds: 150),
                child: _FullscreenIconButton(
                  icon: Icons.fullscreen_rounded,
                  tooltip: "Fullscreen",
                  onTap: _enterFullscreen,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      label: widget.semanticsLabel,
      child: MouseRegion(
        onEnter: (_) => _setHovering(true),
        onExit: (_) => _setHovering(false),
        child: content,
      ),
    );
  }
}

class _FullscreenIconButton extends StatelessWidget {
  const _FullscreenIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: SovereignColors.textPrimary, size: 20),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The immersive black fullscreen page: the video fills the window, exit is
/// available via the corner control, double-tap, or Esc (desktop).
class _FullscreenVideoPage extends StatelessWidget {
  const _FullscreenVideoPage({
    required this.videoListenable,
    required this.overlayListenable,
    required this.aspectRatio,
    required this.onExit,
  });

  final ValueListenable<Widget> videoListenable;
  final ValueListenable<Widget?> overlayListenable;
  final double aspectRatio;
  final VoidCallback onExit;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      onExit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Double-tap anywhere on the video surface exits. Kept as a
              // sibling of (not ancestor of) the exit button below so the
              // button's single tap resolves immediately, no gesture-arena
              // double-tap wait.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: onExit,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: aspectRatio,
                    child: ValueListenableBuilder<Widget>(
                      valueListenable: videoListenable,
                      builder: (context, video, _) => video,
                    ),
                  ),
                ),
              ),
              ValueListenableBuilder<Widget?>(
                valueListenable: overlayListenable,
                builder: (context, overlay, _) =>
                    overlay ?? const SizedBox.shrink(),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: _FullscreenIconButton(
                  icon: Icons.fullscreen_exit_rounded,
                  tooltip: "Exit fullscreen (Esc)",
                  onTap: onExit,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
