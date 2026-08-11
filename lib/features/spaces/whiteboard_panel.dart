import "dart:ui" show PointMode;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/backend_config.dart" show backendConfigProvider;
import "../../services/lane_service.dart";
import "../../services/livekit_call_service.dart";

/// Collaborative whiteboard lane (Tier 4): a shared freehand drawing surface
/// synced across the Space over the data-lane substrate. The "whiteboard" lane
/// is a SNAPSHOT lane, each stroke-end publishes the full current state and the
/// latest snapshot wins. State is persisted + replayed (catch-up) for late
/// joiners, who receive the latest snapshot as a 1-element list.
class WhiteboardPanel extends ConsumerStatefulWidget {
  const WhiteboardPanel({super.key, required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  ConsumerState<WhiteboardPanel> createState() => _WhiteboardPanelState();
}

class _WhiteboardPanelState extends ConsumerState<WhiteboardPanel> {
  late final LaneService _lane;

  /// All completed strokes plus the in-progress one (last element while drawing).
  /// Each stroke is a list of points.
  final List<List<Offset>> _strokes = [];

  @override
  void initState() {
    super.initState();
    _lane = LaneService(
      livekit: ref.read(liveKitCallServiceProvider),
      // RUNTIME base, not the compile-time constant: kDefaultWebuiUrl is ""
      // unless a dart-define sets it, and the web deploy does not, so an
      // empty base sent every HTTP call into LaneService's swallowing catch
      // and silently killed this lane's catch-up replay.
      baseUrl: ref.read(backendConfigProvider).skchatWebuiUrl,
      spaceId: widget.spaceId,
    );
    _lane.catchUp("whiteboard").then((events) {
      // Snapshot lane: the latest snapshot wins, apply the last event.
      if (events.isNotEmpty) {
        _applyRemote(events.last);
      }
    });
    _lane.inbound.where((j) => j["lane"] == "whiteboard").listen(_applyRemote);
  }

  /// Apply an inbound whiteboard snapshot WITHOUT re-publishing (avoids loops).
  void _applyRemote(Map<String, dynamic> e) {
    final raw = e["strokes"];
    if (raw is! List) return;
    final next = _deserialize(raw);
    if (!mounted) return;
    setState(() {
      _strokes
        ..clear()
        ..addAll(next);
    });
  }

  /// strokes wire shape: List<List<Map<String,double>>>, each point {"x","y"}.
  List<List<Offset>> _deserialize(List raw) {
    final out = <List<Offset>>[];
    for (final stroke in raw) {
      if (stroke is! List) continue;
      final pts = <Offset>[];
      for (final p in stroke) {
        if (p is Map) {
          final x = (p["x"] as num?)?.toDouble();
          final y = (p["y"] as num?)?.toDouble();
          if (x != null && y != null) pts.add(Offset(x, y));
        }
      }
      out.add(pts);
    }
    return out;
  }

  List<List<Map<String, double>>> _serialize(List<List<Offset>> strokes) {
    return strokes
        .map((stroke) =>
            stroke.map((o) => {"x": o.dx, "y": o.dy}).toList())
        .toList();
  }

  /// Publish the full current snapshot (snapshot lane, latest full state wins).
  Future<void> _publishSnapshot() async {
    await _lane.publish({
      "lane": "whiteboard",
      "from": widget.identity,
      "strokes": _serialize(_strokes),
    });
  }

  void _onPanStart(DragStartDetails d) {
    setState(() => _strokes.add([d.localPosition]));
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.last.add(d.localPosition));
  }

  void _onPanEnd(DragEndDetails d) {
    _publishSnapshot();
  }

  void _clear() {
    setState(_strokes.clear);
    _publishSnapshot();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            "Whiteboard",
            style: TextStyle(
              color: SovereignColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  color: SovereignColors.surfaceRaised,
                  border: Border.all(color: SovereignColors.surfaceGlassBorder),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: CustomPaint(
                    painter: _WhiteboardPainter(_strokes),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _clear,
                child: const Text("Clear",
                    style: TextStyle(color: SovereignColors.accentDanger)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Draws every stroke as a connected polyline.
class _WhiteboardPainter extends CustomPainter {
  _WhiteboardPainter(this.strokes);

  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = SovereignColors.textPrimary
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      if (stroke.length == 1) {
        // A single tap: draw a dot.
        canvas.drawPoints(PointMode.points, stroke, paint);
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_WhiteboardPainter oldDelegate) => true;
}
