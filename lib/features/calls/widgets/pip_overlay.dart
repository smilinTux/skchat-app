import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/sovereign_colors.dart';
import '../call_session.dart';

/// Floating picture-in-picture overlay shown while the active call is
/// minimized ([CallSession.minimize]).
///
/// Draggable mini pill pinned to the top-right corner. Tapping it restores
/// the call ([CallSession.restore]); the pill's own hang-up button ends the
/// call outright ([CallSession.hangUp]). Shown on top of all other content
/// via an Overlay, so it survives navigation between screens (mounted once,
/// high in the tree, e.g. AppShell).
class PiPOverlay extends ConsumerStatefulWidget {
  const PiPOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PiPOverlay> createState() => _PiPOverlayState();
}

class _PiPOverlayState extends ConsumerState<PiPOverlay> {
  OverlayEntry? _entry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Defer to after this build frame: inserting an OverlayEntry synchronously
    // here (e.g. on first mount with an already-minimized session) trips
    // "setState() or markNeedsBuild() called during build" because the
    // ancestor Overlay is still mid-build at this point.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncOverlay(ref.read(callSessionProvider));
    });
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  bool _isPip(CallSessionState? s) =>
      s != null &&
      (s.isMinimized || s.status == CallSessionStatus.minimized);

  void _syncOverlay(CallSessionState? s) {
    final isPip = _isPip(s);
    if (isPip && _entry == null) {
      _showOverlay();
    } else if (!isPip && _entry != null) {
      _removeOverlay();
    }
  }

  /// The entry's own builder watches [callSessionProvider] directly (via the
  /// [Consumer] below), so once shown the pill stays live for name/status
  /// changes without this State needing to tear down and recreate the entry.
  void _showOverlay() {
    _entry = OverlayEntry(
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final call = ref.watch(callSessionProvider);
          if (!_isPip(call)) return const SizedBox.shrink();
          return _PiPWindow(
            call: call!,
            onTap: () {
              final peer = call.peer;
              ref.read(callSessionProvider.notifier).restore();
              // Land on the peer's conversation, where the in-thread
              // CallBanner gives mute/hang-up/expand for the restored call.
              // Pushing the LiveKit call screen directly here would re-join
              // the room on init and disrupt the live call, so this is the
              // safe target for now; a full-screen expand without rejoin is
              // a Phase 2b follow-up.
              context.push(AppRoutes.conversationPath(peer));
            },
            onHangUp: () => ref.read(callSessionProvider.notifier).hangUp(),
          );
        },
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<CallSessionState?>(callSessionProvider, (prev, next) {
      _syncOverlay(next);
    });

    return widget.child;
  }
}

/// The draggable mini window content.
class _PiPWindow extends StatefulWidget {
  const _PiPWindow({
    required this.call,
    required this.onTap,
    required this.onHangUp,
  });

  final CallSessionState call;
  final VoidCallback onTap;
  final VoidCallback onHangUp;

  @override
  State<_PiPWindow> createState() => _PiPWindowState();
}

class _PiPWindowState extends State<_PiPWindow> {
  double _right = 16;
  double _top = 80;

  @override
  Widget build(BuildContext context) {
    final soul = SovereignColors.fromFingerprint(widget.call.peer);
    return Positioned(
      right: _right,
      top: _top,
      child: GestureDetector(
        key: const Key('call-pip-window'),
        onPanUpdate: (d) {
          setState(() {
            _right = (_right - d.delta.dx).clamp(0.0, 300.0);
            _top = (_top + d.delta.dy).clamp(
              MediaQuery.of(context).padding.top,
              MediaQuery.of(context).size.height - 140,
            );
          });
        },
        onTap: widget.onTap,
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 100,
              height: 130,
              decoration: BoxDecoration(
                color: SovereignColors.surfaceRaised,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: soul.withValues(alpha: 0.5),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  _PiPAvatar(peerName: widget.call.peerName, soulColor: soul),

                  // Peer-name strip.
                  Positioned(
                    bottom: 28,
                    left: 0,
                    right: 0,
                    child: Text(
                      widget.call.peerName,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),

                  // Hang-up button.
                  Positioned(
                    bottom: 6,
                    left: 0,
                    right: 0,
                    child: GestureDetector(
                      key: const Key('call-pip-hangup'),
                      onTap: widget.onHangUp,
                      child: const Center(
                        child: Icon(
                          Icons.call_end_rounded,
                          color: SovereignColors.accentDanger,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Voice-call fallback content: peer-initial avatar over a soul-color wash.
/// (No live video preview here: the LiveKit render surface lives on the
/// full-screen call view; the pill is a lightweight return-to-call handle.)
class _PiPAvatar extends StatelessWidget {
  const _PiPAvatar({required this.peerName, required this.soulColor});

  final String peerName;
  final Color soulColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: soulColor.withValues(alpha: 0.12),
      child: Center(
        child: Text(
          peerName.isNotEmpty ? peerName[0].toUpperCase() : '?',
          style: TextStyle(
            color: soulColor,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
