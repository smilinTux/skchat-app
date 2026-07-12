import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../core/theme/sovereign_colors.dart';

/// Subtle three-bar signal indicator for a participant's LiveKit connection
/// quality (the link between them and the SFU).
///
/// Driven by [ConnectionQuality] from `Participant.connectionQuality`, which the
/// call service refreshes on every `ParticipantConnectionQualityUpdatedEvent`.
/// Rendering is deliberately lightweight: a fixed row of three tiny bars whose
/// fill count and color reflect the quality bucket.
///
/// - excellent / good : all bars, emerald (a healthy link, so this stays quiet).
/// - poor             : one bar, amber (a warning the user can act on).
/// - lost             : one dim bar, red.
/// - unknown          : nothing rendered (SizedBox.shrink) until the first
///                      server estimate arrives, so a fresh tile is not noisy.
class ConnectionQualityBars extends StatelessWidget {
  const ConnectionQualityBars({
    super.key,
    required this.quality,
    this.size = 12,
  });

  /// The participant's current connection quality.
  final ConnectionQuality quality;

  /// Overall height of the bars in logical pixels; width scales with it.
  final double size;

  @override
  Widget build(BuildContext context) {
    // Nothing to show before the SFU has reported a quality estimate.
    if (quality == ConnectionQuality.unknown) {
      return const SizedBox.shrink();
    }

    final int filled;
    final Color color;
    switch (quality) {
      case ConnectionQuality.excellent:
      case ConnectionQuality.good:
        filled = 3;
        color = SovereignColors.accentEncrypt;
      case ConnectionQuality.poor:
        filled = 1;
        color = SovereignColors.accentWarning;
      case ConnectionQuality.lost:
        filled = 0;
        color = SovereignColors.accentDanger;
      case ConnectionQuality.unknown:
        filled = 0;
        color = SovereignColors.textTertiary;
    }

    // Three bars of increasing height, filled up to [filled], with an empty
    // (dim) bar rendered as a faint outline so the widget footprint is stable.
    final barWidth = size * 0.22;
    return Tooltip(
      message: 'Connection: ${_label(quality)}',
      child: SizedBox(
        height: size,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: barWidth * 0.5),
              Container(
                width: barWidth,
                height: size * (0.5 + i * 0.25),
                decoration: BoxDecoration(
                  color: i < filled
                      ? color
                      : color.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _label(ConnectionQuality q) => switch (q) {
        ConnectionQuality.excellent => 'excellent',
        ConnectionQuality.good => 'good',
        ConnectionQuality.poor => 'poor',
        ConnectionQuality.lost => 'lost',
        ConnectionQuality.unknown => 'unknown',
      };
}
