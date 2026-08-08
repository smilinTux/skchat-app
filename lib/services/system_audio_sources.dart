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

  /// Tokens that identify a REAL capture device fed by desktop audio rather
  /// than by a microphone: an snd-aloop input, or a PipeWire virtual source.
  ///
  /// This is a strict ALLOWLIST, never a mic denylist. That direction matters:
  /// the physical mic on .41 is labelled "Built-in Audio Analog Stereo" and
  /// carries no "mic"-ish token at all, so anything but an allowlist would
  /// eventually classify a microphone as system audio and silently recreate
  /// the blended-audio bug (see the class doc on [captureOptions]).
  static const List<String> _loopbackTokens = [
    'loopback',
    'snd_aloop',
    'aloop',
    'virtual source',
    'virtual sink',
    'null output',
    'null sink',
  ];

  /// True when [device] is a real capture device carrying desktop audio.
  ///
  /// This is the ONLY system-audio path that works on web: browsers never
  /// surface a PulseAudio monitor (see [isMonitor] / the class doc), but they
  /// do surface snd-aloop inputs and PipeWire virtual sources as ordinary
  /// input devices, because to the browser that is exactly what they are.
  static bool isLoopbackCapture(MediaDevice device) {
    if (isMonitor(device)) return false;
    final s = '${device.deviceId} ${device.label}'.toLowerCase();
    return _loopbackTokens.any(s.contains);
  }

  /// The loopback / virtual capture inputs among [devices], preserving order.
  static List<MediaDevice> loopbackCaptures(List<MediaDevice> devices) =>
      devices.where(isLoopbackCapture).toList(growable: false);

  /// Every device that can carry system audio: monitors first (the native
  /// desktop path), then loopback / virtual captures (the web path).
  static List<MediaDevice> candidates(List<MediaDevice> devices) => [
    ...monitors(devices),
    ...loopbackCaptures(devices),
  ];

  /// Auto-select the best default system-audio source, else null when the
  /// platform exposes nothing that can carry it.
  ///
  /// Monitors win when present: they are the verified native-desktop path and
  /// capture the whole default sink. Only when there is no monitor at all
  /// (i.e. on web) does this fall back to a loopback / virtual capture, which
  /// is also the more precise source, since it carries only the app routed
  /// into it rather than everything playing on the box.
  static MediaDevice? autoSelect(List<MediaDevice> devices) {
    final mons = monitors(devices);
    if (mons.isNotEmpty) {
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
    final loops = loopbackCaptures(devices);
    return loops.isEmpty ? null : loops.first;
  }

  /// Capture options for a raw system-audio track: all WebRTC voice processing
  /// off, so music and video content is not gated or pumped into artifacts.
  ///
  /// LINUX CAVEAT (see docs/spaces-system-audio-linux.md). Two DIFFERENT Linux
  /// failures produce the same symptom (listeners hear the mic, with content
  /// bleeding in acoustically), so keep them apart:
  ///
  /// NATIVE: the bundled libwebrtc ADM enumerates zero audio devices, so
  /// [monitors] is always empty there and this path is never reached from the
  /// panel. Do NOT try to "fix" that by feeding a PulseAudio monitor name in
  /// here as [deviceId]: verified on .41 that `RecordingDevices() == 0` makes
  /// the deviceId a no-op, so WebRTC stays on the default mic and you silently
  /// re-capture the microphone under a "system audio" label, recreating the
  /// echo. Native needs an out-of-band monitor capture (the vendored
  /// flutter_webrtc PulseLoopbackCapturer), not this constraint.
  ///
  /// WEB: the browser never exposes a monitor at all. Chromium filters
  /// PulseAudio monitor sources out of `enumerateDevices`, and web deviceIds
  /// are hashed opaque strings that can never end in ".monitor", so [isMonitor]
  /// is structurally unsatisfiable and [monitors] is always empty (verified
  /// live over CDP against Brave 150 on .41). Here the deviceId IS honoured, so
  /// the fix is to select a real capture device fed by desktop audio, see
  /// [isLoopbackCapture].
  static AudioCaptureOptions captureOptions(String deviceId) =>
      AudioCaptureOptions(
        deviceId: deviceId,
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
      );
}
