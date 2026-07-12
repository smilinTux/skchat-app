import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:url_launcher/url_launcher.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/cast_service.dart";
import "cast_stage_stub.dart" if (dart.library.html) "cast_stage_web.dart";

/// The HLS cast session currently active for the app, or null.
///
/// Set when a "Cast to TV" sheet starts (or reuses) an egress, cleared when the
/// user explicitly stops casting. The control bars watch this to show a "live"
/// state on the cast button. The egress itself also stops server-side when the
/// room empties (a RoomComposite egress ends with its room), so a dismissed
/// sheet does not orphan a cast: the TV keeps playing until you stop it or the
/// call ends.
final activeCastSessionProvider =
    StateProvider<HlsCastSession?>((ref) => null);

/// Open the "Cast to TV" sheet for [room].
///
/// Starts (or reuses) an HLS egress for the room and presents a preview plus the
/// Chromecast / AirPlay / open-on-TV controls. The LiveKit call is NOT touched:
/// the phone keeps its WebRTC mic + chat while the separate HLS stream goes to
/// the TV. Dismissing the sheet leaves the cast running; "Stop casting" ends it.
Future<void> showCastToTvSheet(
  BuildContext context,
  WidgetRef ref, {
  required String room,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SovereignColors.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CastSheetBody(room: room),
  );
}

class _CastSheetBody extends ConsumerStatefulWidget {
  const _CastSheetBody({required this.room});

  final String room;

  @override
  ConsumerState<_CastSheetBody> createState() => _CastSheetBodyState();
}

class _CastSheetBodyState extends ConsumerState<_CastSheetBody> {
  CastController? _controller;
  HlsCastSession? _session;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final svc = ref.read(castServiceProvider);
      final session = await svc.start(widget.room);
      if (!mounted) return;
      if (session.hlsUrl.isEmpty) {
        setState(() {
          _error = "The server did not return a stream URL.";
          _loading = false;
        });
        return;
      }
      final controller = createCastController(session.hlsUrl);
      ref.read(activeCastSessionProvider.notifier).state = session;
      setState(() {
        _session = session;
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst("Exception: ", "");
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    // Tear down the in-app preview element. This does NOT stop the egress: the
    // TV keeps playing (Chromecast plays the URL on the receiver independently),
    // and the egress self-stops when the room empties. Use "Stop casting" for an
    // immediate stop.
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _stopCasting() async {
    final session = _session;
    _controller?.dispose();
    _controller = null;
    if (session != null) {
      await ref.read(castServiceProvider).stop(session.egressId);
    }
    ref.read(activeCastSessionProvider.notifier).state = null;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _chromecast() async {
    final controller = _controller;
    if (controller == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await controller.requestChromecast();
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "No Chromecast started. Make sure a Cast device is on this "
            "network, or use Open on TV.",
          ),
        ),
      );
    }
  }

  Future<void> _openOnTv() async {
    final url = _session?.hlsUrl ?? "";
    if (url.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: url));
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? "Opened the stream. The link is also copied for your TV browser."
              : "Stream link copied. Paste it into your TV's browser or VLC.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grab handle.
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              alignment: Alignment.center,
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SovereignColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(
                children: [
                  Icon(Icons.cast_rounded,
                      color: SovereignColors.soulLumina, size: 20),
                  SizedBox(width: 8),
                  Text(
                    "Cast to TV",
                    style: TextStyle(
                      color: SovereignColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Video preview / loading / error.
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: SovereignColors.surfaceGlassBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildStage(controller),
              ),
            ),

            const SizedBox(height: 12),

            // Latency note (honest UX).
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: SovereignColors.textTertiary, size: 15),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "The TV runs a few seconds behind the live call (HLS "
                      "buffers). Your phone keeps the live audio and chat.",
                      style: TextStyle(
                        color: SovereignColors.textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Cast action buttons.
            if (controller != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    _CastActionButton(
                      icon: Icons.cast_rounded,
                      label: "Chromecast",
                      onTap: _chromecast,
                    ),
                    if (controller.airplayAvailable())
                      _CastActionButton(
                        icon: Icons.airplay_rounded,
                        label: "AirPlay",
                        onTap: controller.showAirplay,
                      ),
                    _CastActionButton(
                      icon: Icons.open_in_new_rounded,
                      label: "Open on TV",
                      onTap: _openOnTv,
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Bottom row: keep-casting (dismiss) + stop.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: SovereignColors.textSecondary,
                        side: const BorderSide(
                            color: SovereignColors.surfaceGlassBorder),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text("Keep casting, back to call"),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _session == null && !_loading ? null : _stopCasting,
                      style: FilledButton.styleFrom(
                        backgroundColor: SovereignColors.accentDanger,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text("Stop casting"),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStage(CastController? controller) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: SovereignColors.soulLumina,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            "Could not start the TV stream.\n$_error",
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: SovereignColors.accentWarning, fontSize: 13),
          ),
        ),
      );
    }
    if (controller == null) return const SizedBox.shrink();
    return CastStage(controller: controller);
  }
}

/// Pill-shaped cast action button used inside the sheet.
class _CastActionButton extends StatelessWidget {
  const _CastActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: SovereignColors.textPrimary,
        backgroundColor: SovereignColors.surfaceGlass,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: SovereignColors.surfaceGlassBorder),
        ),
      ),
      icon: Icon(icon, size: 18, color: SovereignColors.soulLumina),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }
}
