import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/sovereign_colors.dart';

/// In-call elapsed timer.
///
/// Starts counting the moment [isConnected] first flips to true and keeps a
/// single 1s periodic ticker running while mounted. Renders MM:SS under an
/// hour and HH:MM:SS once the call passes 60 minutes. Renders nothing until
/// the media session is connected, so the top bar stays quiet while the room
/// is still joining.
///
/// The ticker is owned by this widget's state (cancelled on dispose), so it
/// tears down automatically when the caller leaves the call and unmounts the
/// screen. Drop it into a call/conf/space top bar as a subtitle badge.
class CallElapsedTimer extends StatefulWidget {
  const CallElapsedTimer({
    super.key,
    required this.isConnected,
    this.style,
  });

  /// Whether the media session is currently connected. The timer latches its
  /// start time the first time this reads true and does not reset on a brief
  /// reconnect blip.
  final bool isConnected;

  /// Optional text style override. Falls back to a compact mono badge style.
  final TextStyle? style;

  @override
  State<CallElapsedTimer> createState() => _CallElapsedTimerState();
}

class _CallElapsedTimerState extends State<CallElapsedTimer> {
  Timer? _ticker;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    if (widget.isConnected) _start();
  }

  @override
  void didUpdateWidget(covariant CallElapsedTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isConnected && _startedAt == null) _start();
  }

  void _start() {
    _startedAt = DateTime.now();
    _ticker?.cancel();
    // Rebuild once a second so the elapsed readout advances.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final hh = hours.toString().padLeft(2, '0');
      return '$hh:$mm:$ss';
    }
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final started = _startedAt;
    if (started == null) return const SizedBox.shrink();
    final elapsed = DateTime.now().difference(started);
    return Text(
      _format(elapsed),
      style: widget.style ??
          const TextStyle(
            color: SovereignColors.textSecondary,
            fontSize: 12,
            fontFamily: 'JetBrainsMono',
            letterSpacing: 0.4,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
    );
  }
}
