import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";
import "../../services/system_audio_sources.dart";
import "screen_share_helper.dart";

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
  bool _shareSystemAudio = true;
  String? _systemAudioDeviceId;
  List<MediaDevice> _monitors = const [];

  @override
  void initState() {
    super.initState();
    _loadSystemAudioSources();
  }

  Future<void> _loadSystemAudioSources() async {
    List<MediaDevice> monitors = const [];
    String? defaultId;
    try {
      final list = await Hardware.instance.enumerateDevices(
        type: 'audioinput',
      );
      monitors = SystemAudioSources.monitors(list);
      defaultId = SystemAudioSources.autoSelect(list)?.deviceId;
    } catch (_) {
      // Leave _monitors empty; the switch already disables itself and shows
      // the hint when there is nothing to select.
    }
    if (mounted) {
      setState(() {
        _monitors = monitors;
        _systemAudioDeviceId = defaultId;
      });
    }
  }

  Future<void> _toggleShare() async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = !_sharing;
    try {
      String? sourceId;
      if (next) {
        // Desktop needs an explicit capture source before getDisplayMedia
        // can resolve one; web keeps using its own native picker. A
        // cancelled desktop pick aborts silently, no share, no error.
        final picked = await resolveScreenShareSource(context);
        if (!picked.proceed) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        sourceId = picked.sourceId;
      }
      await ref.read(liveKitCallServiceProvider).setScreenShareEnabled(
            next,
            systemAudioDeviceId:
                (_shareSystemAudio && next) ? _systemAudioDeviceId : null,
            sourceId: sourceId,
          );
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

          // Remote screen-share tracks, rendered live from the LiveKit room.
          Expanded(
            child: StreamBuilder<List<LiveKitParticipantSnapshot>>(
              stream: svc.participants,
              initialData: svc.currentParticipants,
              builder: (context, snap) {
                final room = svc.room;
                final participants = snap.data ?? const [];
                // Remote shares only here (the local user has the toggle below).
                final shares = resolveScreenShares(room, participants)
                    .where((s) => !s.isLocal)
                    .toList();

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

          // System-audio switch + monitor-source picker.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text(
              "Share system audio",
              style: TextStyle(
                color: SovereignColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: _monitors.isEmpty
                ? const Text(
                    "No system-audio source found on this device.",
                    style: TextStyle(
                      color: SovereignColors.textTertiary,
                      fontSize: 12,
                    ),
                  )
                : null,
            value: _shareSystemAudio,
            onChanged: _monitors.isEmpty
                ? null
                : (value) => setState(() => _shareSystemAudio = value),
          ),
          if (_shareSystemAudio && _monitors.length > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: DropdownButton<String>(
                value: _systemAudioDeviceId,
                dropdownColor: SovereignColors.surfaceCard,
                style: const TextStyle(
                  color: SovereignColors.textPrimary,
                  fontSize: 13,
                ),
                items: [
                  for (final m in _monitors)
                    DropdownMenuItem<String>(
                      value: m.deviceId,
                      child: Text(m.label),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _systemAudioDeviceId = value),
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
}
