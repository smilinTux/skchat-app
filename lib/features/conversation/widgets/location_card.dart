import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/sovereign_colors.dart';
import '../location/location_payload.dart';

/// Map-pin card for a `content_type: "location"` message.
///
/// Renders a lightweight static OSM thumbnail + the lat/lon (and label, if any)
/// + an "Open in Maps" affordance. Tapping anywhere opens the external map
/// (OpenStreetMap) via `url_launcher`. No native map SDK is pulled in for this
/// phase, the thumbnail is a static tile image with a drawn-pin fallback.
///
/// If [payload] is null (a location message with no/garbled `rich`), the caller
/// should fall back to the body text (Golden rule), this widget only renders a
/// real pin.
class LocationCard extends StatelessWidget {
  const LocationCard({
    super.key,
    required this.payload,
    this.textColor = SovereignColors.textPrimary,
  });

  final LocationPayload payload;
  final Color textColor;

  Future<void> _open() async {
    final uri = Uri.parse(payload.mapsUrl());
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort: a blocked popup / unsupported launcher is non-fatal.
    }
  }

  @override
  Widget build(BuildContext context) {
    final coords =
        '${payload.lat.toStringAsFixed(payload.precise ? 6 : 3)}, '
        '${payload.lon.toStringAsFixed(payload.precise ? 6 : 3)}';
    return GestureDetector(
      onTap: _open,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              color: SovereignColors.surfaceRaised,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: SovereignColors.surfaceGlassBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Thumb(payload: payload),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.location_on,
                              size: 18, color: SovereignColors.accentDanger),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              payload.label?.isNotEmpty == true
                                  ? payload.label!
                                  : 'Shared location',
                              style: TextStyle(
                                color: textColor,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!payload.precise)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: SovereignColors.accentWarning
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'approx.',
                                style: TextStyle(
                                  color: SovereignColors.accentWarning,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        coords,
                        style: const TextStyle(
                          color: SovereignColors.textSecondary,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.open_in_new,
                              size: 14, color: SovereignColors.accentEncrypt),
                          SizedBox(width: 4),
                          Text(
                            'Open in Maps',
                            style: TextStyle(
                              color: SovereignColors.accentEncrypt,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Static map thumbnail. Tries an OSM static-tile image; on any load error it
/// shows a drawn pin placeholder so the card never renders broken.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.payload});
  final LocationPayload payload;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      width: double.infinity,
      child: Image.network(
        payload.staticThumbUrl(width: 320, height: 140),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => const _ThumbFallback(),
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : const _ThumbFallback(loading: true),
      ),
    );
  }
}

class _ThumbFallback extends StatelessWidget {
  const _ThumbFallback({this.loading = false});
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SovereignColors.surfaceCard,
      alignment: Alignment.center,
      child: loading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                    SovereignColors.textTertiary),
              ),
            )
          : const Icon(Icons.map_outlined,
              size: 40, color: SovereignColors.textTertiary),
    );
  }
}
