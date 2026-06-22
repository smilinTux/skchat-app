import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/theme.dart';
import 'geo_unit.dart';
import 'skmap_providers.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// SkMapScreen — the tactical map ("ours, ATAK-style").
/// ─────────────────────────────────────────────────────────────────────────
///
/// Renders the live CoT / geo unit picture on an OpenStreetMap base layer:
///   * friendly units (`a-f-*`) as blue markers,
///   * map markers (`b-m-*`) as yellow markers,
///   * hostile/neutral/unknown coloured accordingly,
///   * tap a unit → a bottom sheet with callsign / coords / last-seen,
///   * "recenter on me" + "fit all units" controls.
///
/// Data comes from [geoUnitsProvider] (a feed-agnostic stream). v1 is the mock
/// feed; see `geo_units_source.dart` for the live-feed adapter seam.
class SkMapScreen extends ConsumerStatefulWidget {
  const SkMapScreen({super.key});

  @override
  ConsumerState<SkMapScreen> createState() => _SkMapScreenState();
}

class _SkMapScreenState extends ConsumerState<SkMapScreen> {
  final MapController _map = MapController();

  /// Lower-Manhattan default view (matches the CoT bridge sample coords) until
  /// the first snapshot arrives.
  static const _initialCenter = LatLng(40.7589, -73.9851);
  static const _initialZoom = 13.0;

  /// "On me" anchor. The real operator position will come from the local
  /// node's own GeoUnit (self-uid) once the live feed lands; for v1 we fall
  /// back to the LUMINA unit / first unit, then the initial center.
  LatLng? _operatorPos(List<GeoUnit> units) {
    for (final u in units) {
      if (u.uid == 'LUMINA') return u.position;
    }
    return units.isNotEmpty ? units.first.position : null;
  }

  void _recenterOnMe(List<GeoUnit> units) {
    final me = _operatorPos(units) ?? _initialCenter;
    _map.move(me, 15);
  }

  void _fitAll(List<GeoUnit> units) {
    if (units.isEmpty) return;
    if (units.length == 1) {
      _map.move(units.first.position, 15);
      return;
    }
    final pts = units.map((u) => u.position).toList();
    final bounds = LatLngBounds.fromPoints(pts);
    _map.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(64),
        maxZoom: 16,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unitsAsync = ref.watch(geoUnitsProvider);
    final selectedUid = ref.watch(selectedUnitProvider);
    final units = unitsAsync.valueOrNull ?? const <GeoUnit>[];

    // When the selected unit changes (or new data arrives), surface its sheet.
    ref.listen<String?>(selectedUnitProvider, (prev, next) {
      if (next == null) return;
      final unit = _findUnit(units, next);
      if (unit != null) _showUnitSheet(unit);
    });

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            _buildMap(units, selectedUid),
            _buildHeader(units, unitsAsync),
            _buildControls(units),
            if (unitsAsync.isLoading && units.isEmpty)
              const Center(child: CircularProgressIndicator()),
            if (unitsAsync.hasError && units.isEmpty)
              _buildError(unitsAsync.error.toString()),
          ],
        ),
      ),
    );
  }

  Widget _buildMap(List<GeoUnit> units, String? selectedUid) {
    final now = DateTime.now().toUtc();
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _initialCenter,
        initialZoom: _initialZoom,
        minZoom: 2,
        maxZoom: 18,
        // Tapping empty map clears the selection.
        onTap: (_, position) =>
            ref.read(selectedUnitProvider.notifier).state = null,
      ),
      children: [
        TileLayer(
          // OpenStreetMap — no API key. Offline-tile capable: point urlTemplate
          // at a local mbtiles/file provider for fully sovereign operation.
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'io.skworld.skchat',
          tileProvider: NetworkTileProvider(),
        ),
        MarkerLayer(
          markers: [
            for (final u in units)
              Marker(
                point: u.position,
                width: 120,
                height: 64,
                alignment: Alignment.topCenter,
                child: _UnitMarker(
                  unit: u,
                  selected: u.uid == selectedUid,
                  stale: u.isStaleAt(now),
                  onTap: () => ref
                      .read(selectedUnitProvider.notifier)
                      .state = u.uid,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildHeader(List<GeoUnit> units, AsyncValue<List<GeoUnit>> async) {
    final friendly =
        units.where((u) => u.kind == GeoUnitKind.friendly).length;
    final markers = units.where((u) => u.kind == GeoUnitKind.marker).length;
    return Positioned(
      top: 12,
      left: 16,
      right: 16,
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.radar_rounded,
                color: SovereignColors.soulJarvis, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'SkMap',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: SovereignColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    async.isLoading && units.isEmpty
                        ? 'Acquiring feed…'
                        : '$friendly unit${friendly == 1 ? '' : 's'} · '
                            '$markers marker${markers == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: SovereignColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
            if (async.isLoading && units.isNotEmpty)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(List<GeoUnit> units) {
    return Positioned(
      right: 16,
      bottom: 28,
      child: Column(
        children: [
          _MapFab(
            icon: Icons.my_location_rounded,
            tooltip: 'Recenter on me',
            onPressed: () => _recenterOnMe(units),
          ),
          const SizedBox(height: 12),
          _MapFab(
            icon: Icons.zoom_out_map_rounded,
            tooltip: 'Fit all units',
            onPressed: () => _fitAll(units),
          ),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  color: SovereignColors.accentWarning, size: 32),
              const SizedBox(height: 8),
              Text(
                'Geo feed unavailable',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: SovereignColors.textPrimary,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: SovereignColors.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  GeoUnit? _findUnit(List<GeoUnit> units, String uid) {
    for (final u in units) {
      if (u.uid == uid) return u;
    }
    return null;
  }

  void _showUnitSheet(GeoUnit unit) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _UnitDetailsSheet(unit: unit),
    ).whenComplete(() {
      // Clear selection when the sheet is dismissed (if still this unit).
      if (ref.read(selectedUnitProvider) == unit.uid) {
        ref.read(selectedUnitProvider.notifier).state = null;
      }
    });
  }
}

// ── Marker rendering ─────────────────────────────────────────────────────────

Color _kindColor(GeoUnitKind kind) {
  switch (kind) {
    case GeoUnitKind.friendly:
      return SovereignColors.soulJarvis; // blue/cyan = friendly
    case GeoUnitKind.marker:
      return SovereignColors.accentWarning; // yellow/amber = marker
    case GeoUnitKind.hostile:
      return SovereignColors.accentDanger; // red = hostile
    case GeoUnitKind.neutral:
      return SovereignColors.accentEncrypt; // green = neutral
    case GeoUnitKind.unknown:
      return SovereignColors.textSecondary; // grey = unknown
  }
}

IconData _kindIcon(GeoUnitKind kind) {
  switch (kind) {
    case GeoUnitKind.marker:
      return Icons.place_rounded;
    case GeoUnitKind.friendly:
      return Icons.navigation_rounded;
    case GeoUnitKind.hostile:
      return Icons.warning_rounded;
    case GeoUnitKind.neutral:
      return Icons.circle_outlined;
    case GeoUnitKind.unknown:
      return Icons.help_outline_rounded;
  }
}

class _UnitMarker extends StatelessWidget {
  const _UnitMarker({
    required this.unit,
    required this.selected,
    required this.stale,
    required this.onTap,
  });

  final GeoUnit unit;
  final bool selected;
  final bool stale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _kindColor(unit.kind);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: stale ? 0.45 : 1.0,
            child: Container(
              width: selected ? 38 : 32,
              height: selected ? 38 : 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.22),
                shape: BoxShape.circle,
                border: Border.all(
                  color: color,
                  width: selected ? 3 : 2,
                ),
              ),
              child: Icon(_kindIcon(unit.kind),
                  color: color, size: selected ? 20 : 17),
            ),
          ),
          const SizedBox(height: 2),
          DecoratedBox(
            decoration: BoxDecoration(
              color: SovereignColors.surfaceCard.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              child: Text(
                unit.callsign,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: stale
                      ? SovereignColors.textSecondary
                      : SovereignColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapFab extends StatelessWidget {
  const _MapFab({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: SovereignColors.surfaceCard.withValues(alpha: 0.9),
        shape: const CircleBorder(
          side: BorderSide(color: SovereignColors.surfaceGlassBorder),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: SovereignColors.textPrimary, size: 22),
          ),
        ),
      ),
    );
  }
}

// ── Details sheet ────────────────────────────────────────────────────────────

class _UnitDetailsSheet extends StatelessWidget {
  const _UnitDetailsSheet({required this.unit});

  final GeoUnit unit;

  @override
  Widget build(BuildContext context) {
    final color = _kindColor(unit.kind);
    final coords =
        '${unit.lat.toStringAsFixed(5)}, ${unit.lon.toStringAsFixed(5)}';
    final lastSeen = _formatLastSeen(unit.lastSeen);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: GlassCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                      border: Border.all(color: color, width: 2),
                    ),
                    child: Icon(_kindIcon(unit.kind), color: color, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          unit.callsign,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                color: SovereignColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          _kindLabel(unit.kind) +
                              (unit.cotType != null
                                  ? ' · ${unit.cotType}'
                                  : ''),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: color),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _DetailRow(
                  icon: Icons.gps_fixed_rounded,
                  label: 'Coordinates',
                  value: coords),
              const SizedBox(height: 10),
              _DetailRow(
                  icon: Icons.schedule_rounded,
                  label: 'Last seen',
                  value: lastSeen),
              if (unit.remarks != null && unit.remarks!.isNotEmpty) ...[
                const SizedBox(height: 10),
                _DetailRow(
                    icon: Icons.notes_rounded,
                    label: 'Remarks',
                    value: unit.remarks!),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: SovereignColors.textTertiary),
        const SizedBox(width: 10),
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: SovereignColors.textSecondary,
                ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: SovereignColors.textPrimary,
                  fontFeatures: const [],
                ),
          ),
        ),
      ],
    );
  }
}

String _kindLabel(GeoUnitKind kind) {
  switch (kind) {
    case GeoUnitKind.friendly:
      return 'Friendly unit';
    case GeoUnitKind.marker:
      return 'Marker';
    case GeoUnitKind.hostile:
      return 'Hostile';
    case GeoUnitKind.neutral:
      return 'Neutral';
    case GeoUnitKind.unknown:
      return 'Unknown';
  }
}

String _formatLastSeen(DateTime lastSeen) {
  final now = DateTime.now().toUtc();
  final diff = now.difference(lastSeen);
  final abs = '${DateFormat.Hms().format(lastSeen.toLocal())} '
      '${DateFormat.yMd().format(lastSeen.toLocal())}';
  if (diff.inSeconds < 5) return 'just now · $abs';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago · $abs';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago · $abs';
  if (diff.inHours < 24) return '${diff.inHours}h ago · $abs';
  return abs;
}
