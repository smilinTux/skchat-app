import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:livekit_client/livekit_client.dart";

import "../../../core/theme/theme.dart";
import "../../../services/livekit_call_service.dart";
import "../../../services/peer_trust_store.dart";
import "../../identity/widgets/trust_badge.dart";
import "../connection_quality_bars.dart";
import "../soul_color.dart";
import "participant_video.dart";

/// One tile in a video grid: live video when there is any, the audio-only
/// avatar presentation when there is not, plus the name / trust / quality /
/// mic strip along the bottom.
///
/// Lifted verbatim out of `features/calls/livekit_call_screen.dart`, where it
/// was private. The calls screen had the only working multi-party video tile
/// in the app and Spaces had nothing comparable, so the tile is shared rather
/// than reinvented: a second implementation would immediately start drifting
/// on the details that matter (the muted-publication rule, the late-arriving
/// track, never badging your own tile).
class ParticipantTile extends ConsumerWidget {
  const ParticipantTile({
    super.key,
    required this.snapshot,
    required this.room,
    this.fullScreen = false,
    this.onLongPress,
  });

  final LiveKitParticipantSnapshot snapshot;
  final Room? room;

  /// Stage presentation: no margin, no border, no corner ring. Used for the
  /// screen-share stage and for a grid that has resolved to a single tile.
  final bool fullScreen;

  /// Optional long-press hook, e.g. a host removing an invited agent from a
  /// conference. Null on every surface that has no such action (calls,
  /// Spaces): the gesture layer only appears when a caller asks for it.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final soul = soulColorFor(snapshot.identity);
    // Per-participant trust tier from the server-set soul_fingerprint (M1b).
    final trustTier = ref
        .watch(peerTrustTierProvider((
          peerId: snapshot.identity,
          fingerprint: snapshot.soulFingerprint,
        )))
        .valueOrNull;
    // Never badge your own tile ("(you)"), no self record -> false red.
    final showTrustBadge = !snapshot.isLocal &&
        (trustTier == PeerTrustTier.red || trustTier == PeerTrustTier.amber);
    // Active-speaker highlight: a brighter, thicker soul-color ring while the
    // participant is speaking (LiveKit audio-level detection).
    final speaking = snapshot.isSpeaking;

    final tile = Container(
      margin: fullScreen ? EdgeInsets.zero : const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: SovereignColors.surfaceCard,
        border: Border.all(
          color: speaking
              ? soul
              : (fullScreen
                  ? Colors.transparent
                  : soul.withValues(alpha: 0.25)),
          width: speaking ? 3 : (fullScreen ? 0 : 1.5),
        ),
        boxShadow: speaking
            ? [BoxShadow(color: soul.withValues(alpha: 0.5), blurRadius: 12)]
            : null,
      ),
      child: Stack(
        fit: fullScreen ? StackFit.expand : StackFit.passthrough,
        children: [
          // Video layer or avatar fallback. Owns its own room-event
          // subscription so a track published AFTER this tile was built (the
          // call agent publishes her portrait once her audio leg is up) paints
          // without waiting on anything else, and a track that goes away mid
          // call falls straight back to the avatar.
          ParticipantVideo(
            room: room,
            snapshot: snapshot,
            fallback: AvatarTile(
              identity: snapshot.identity,
              soulColor: soul,
              isLocal: snapshot.isLocal,
            ),
          ),

          // Bottom info strip, name + mic state.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.65),
                  ],
                ),
              ),
              child: Row(
                children: [
                  // Soul-color ring indicator.
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: soul,
                      boxShadow: [
                        BoxShadow(
                          color: soul.withValues(alpha: 0.6),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Text(
                      snapshot.isLocal
                          ? '${snapshot.identity} (you)'
                          : snapshot.identity,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Inter',
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 4)
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (showTrustBadge) ...[
                    const SizedBox(width: 4),
                    TrustBadge(
                        tier: selfTierForPeer(trustTier!), compact: true),
                  ],
                  // Connection-quality signal bars (subtle; hidden until known).
                  ConnectionQualityBars(quality: snapshot.connectionQuality),
                  // Mic icon.
                  if (snapshot.isMuted)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.mic_off_rounded,
                        color: SovereignColors.accentWarning,
                        size: 14,
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Soul-color corner ring, 3px arc on top-left when not full-screen.
          if (!fullScreen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [soul, soul.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (onLongPress == null) return tile;
    return GestureDetector(onLongPress: onLongPress, child: tile);
  }
}

/// Avatar tile shown when camera is off or unavailable.
class AvatarTile extends StatelessWidget {
  const AvatarTile({
    super.key,
    required this.identity,
    required this.soulColor,
    required this.isLocal,
  });

  final String identity;
  final Color soulColor;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final initials = identity.isNotEmpty ? identity[0].toUpperCase() : '?';

    return Container(
      color: SovereignColors.surfaceCard,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: soulColor.withValues(alpha: 0.15),
                border: Border.all(
                  color: soulColor.withValues(alpha: 0.7),
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: soulColor.withValues(alpha: 0.25),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  initials,
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        color: soulColor,
                      ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
