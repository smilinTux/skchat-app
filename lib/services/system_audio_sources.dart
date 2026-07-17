import 'package:livekit_client/livekit_client.dart';

/// Detection and capture configuration for system-audio sources.
///
/// On Linux desktop the reliable system-audio source is a PulseAudio output
/// monitor (device id ending in ".monitor", label "Monitor of ..."). This
/// helper is pure logic so it can be unit tested without hardware.
class SystemAudioSources {
  /// True when [device] is a PulseAudio output monitor input.
  static bool isMonitor(MediaDevice device) {
    final id = device.deviceId.toLowerCase();
    final label = device.label.toLowerCase();
    return id.endsWith('.monitor') || label.contains('monitor of');
  }

  /// The monitor inputs among [devices], preserving order.
  static List<MediaDevice> monitors(List<MediaDevice> devices) =>
      devices.where(isMonitor).toList(growable: false);

  /// Auto-select the best default monitor: prefer the analog / built-in output,
  /// else the first monitor, else null when none exist.
  static MediaDevice? autoSelect(List<MediaDevice> devices) {
    final mons = monitors(devices);
    if (mons.isEmpty) return null;
    for (final m in mons) {
      final s = '${m.deviceId} ${m.label}'.toLowerCase();
      if (s.contains('analog') ||
          s.contains('built-in') ||
          s.contains('speaker')) {
        return m;
      }
    }
    return mons.first;
  }

  /// Capture options for a raw system-audio track: all WebRTC voice processing
  /// off, so music and video content is not gated or pumped into artifacts.
  static AudioCaptureOptions captureOptions(String deviceId) =>
      AudioCaptureOptions(
        deviceId: deviceId,
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
      );
}
