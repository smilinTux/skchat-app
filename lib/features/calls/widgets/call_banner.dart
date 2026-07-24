import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/sovereign_colors.dart';
import '../../../services/daemon_service.dart';
import '../call_session.dart';
import '../livekit_call_screen.dart';

/// In-thread active-call banner.
///
/// Watches [callSessionProvider] and shows a slim tappable strip at the top
/// of a conversation whenever THIS conversation's peer has a live call
/// (active or minimized), so a minimized call is one tap from the thread it
/// belongs to (tap -> [CallSession.restore] + re-open the full call screen).
///
/// A `failed` session for this peer also surfaces here, with a dismiss
/// affordance instead of a return-to-call affordance: [CallSession.hangUp]
/// clears the session to null. Without this, a failed session has no
/// dismissal path, and while non-null it blocks new incoming rings (see
/// [IncomingCallWatcher.pollOnce], which only polls while the session is
/// null or idle).
class CallBanner extends ConsumerWidget {
  const CallBanner({super.key, required this.peerId});

  final String peerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(callSessionProvider);
    if (s == null || s.peer != peerId) return const SizedBox.shrink();

    if (s.status == CallSessionStatus.failed) {
      return _FailedBanner(peerName: s.peerName);
    }

    final isLive = s.status == CallSessionStatus.active ||
        s.status == CallSessionStatus.minimized;
    if (!isLive) return const SizedBox.shrink();

    return Material(
      key: const Key('call-banner'),
      color: SovereignColors.soulLumina.withValues(alpha: 0.16),
      child: InkWell(
        onTap: () => _returnToCall(context, ref, s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.call_rounded,
                  size: 18, color: SovereignColors.soulLumina),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Tap to return to call with ${s.peerName}'),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  void _returnToCall(BuildContext context, WidgetRef ref, CallSessionState s) {
    ref.read(callSessionProvider.notifier).restore();
    final identity = ref.read(daemonServiceProvider).localIdentity ?? 'me';
    context.push(
      AppRoutes.livekitCall,
      extra: LiveKitCallArgs(
        roomName: s.room,
        identity: identity,
        displayName: s.peerName,
        withVideo: s.isVideo,
        preMintedToken: s.token,
        livekitUrl: s.livekitUrl,
      ),
    );
  }
}

/// Dismissible error strip shown while a call session for this peer is in
/// [CallSessionStatus.failed]. Tapping clears the stranded session.
class _FailedBanner extends ConsumerWidget {
  const _FailedBanner({required this.peerName});

  final String peerName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      key: const Key('call-banner-failed'),
      color: SovereignColors.accentDanger.withValues(alpha: 0.16),
      child: InkWell(
        key: const Key('call-banner-dismiss'),
        onTap: () => ref.read(callSessionProvider.notifier).hangUp(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 18, color: SovereignColors.accentDanger),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Call with $peerName failed. Tap to dismiss.'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
