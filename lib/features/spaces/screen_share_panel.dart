import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";

/// Screen-share lane (Tier 4, MEDIA): publishes a LiveKit screen-share video
/// track from the local participant and renders any REMOTE screen-share tracks
/// live. Unlike the watch / data lanes this rides a real LiveKit media track
/// (`TrackSource.screenShareVideo`), so the renderer is the same
/// [VideoTrackRenderer] used by the call grid.
class ScreenSharePanel extends ConsumerStatefulWidget {
  const ScreenSharePanel({
    super.key,
    required this.spaceId,
    required this.identity,
  });

  final String spaceId;
  final String identity;

  @override
  ConsumerState<ScreenSharePanel> createState() => _ScreenSharePanelState();
}

class _ScreenSharePanelState extends ConsumerState<ScreenSharePanel> {
  bool _sharing = false;
  bool _busy = false;

  Future<void> _toggleShare() async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = !_sharing;
    try {
      await ref
          .read(liveKitCallServiceProvider)
          .setScreenShareEnabled(next);
      if (mounted) setState(() => _sharing = next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Screen share failed: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.read(liveKitCallServiceProvider);

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        color: SovereignColors.surfaceCard,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: SovereignColors.textTertiary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Text(
            "Screen Share",
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),

          // Remote screen-share tracks — rendered live from the LiveKit room.
          Expanded(
            child: StreamBuilder<List<LiveKitParticipantSnapshot>>(
              stream: svc.participants,
              initialData: svc.currentParticipants,
              builder: (context, snap) {
                final room = svc.room;
                final participants = snap.data ?? const [];
                final shares = _resolveRemoteShares(room, participants);

                if (shares.isEmpty) {
                  return const Center(
                    child: Text(
                      "No one is sharing their screen yet.",
                      style: TextStyle(
                        color: SovereignColors.textTertiary,
                        fontSize: 13,
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: shares.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final s = shares[i];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${s.identity} is sharing their screen",
                          style: const TextStyle(
                            color: SovereignColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: VideoTrackRenderer(s.track),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),

          const SizedBox(height: 8),

          // Local share toggle.
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _busy ? null : _toggleShare,
              icon: Icon(
                _sharing
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_rounded,
                color: _sharing
                    ? SovereignColors.accentDanger
                    : SovereignColors.accentEncrypt,
              ),
              label: Text(
                _sharing ? "Stop sharing" : "Share my screen",
                style: TextStyle(
                  color: _sharing
                      ? SovereignColors.accentDanger
                      : SovereignColors.accentEncrypt,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Resolve the live remote screen-share [VideoTrack]s from the [Room].
  ///
  /// The [LiveKitParticipantSnapshot] does not carry the underlying track, so
  /// we look it up in the live room by identity via
  /// `getTrackPublicationBySource(TrackSource.screenShareVideo)` — the same
  /// approach the call grid uses for camera tracks. Local + non-sharing
  /// participants are skipped.
  List<({String identity, VideoTrack track})> _resolveRemoteShares(
    Room? room,
    List<LiveKitParticipantSnapshot> participants,
  ) {
    if (room == null) return const [];
    final out = <({String identity, VideoTrack track})>[];
    for (final p in participants) {
      if (p.isLocal) continue;
      final remote = room.remoteParticipants[p.identity];
      if (remote == null) continue;
      final pub =
          remote.getTrackPublicationBySource(TrackSource.screenShareVideo);
      final track = pub?.track;
      if (track is VideoTrack) {
        out.add((identity: p.identity, track: track as VideoTrack));
      }
    }
    return out;
  }
}
