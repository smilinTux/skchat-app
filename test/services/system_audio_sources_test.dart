// test/services/system_audio_sources_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:skchat/services/system_audio_sources.dart';

MediaDevice _dev(String id, String label) =>
    MediaDevice(id, label, 'audioinput', null);

void main() {
  group('SystemAudioSources', () {
    test('isMonitor detects PulseAudio monitor inputs', () {
      expect(SystemAudioSources.isMonitor(
          _dev('alsa_output.pci-0000_00_1f.3.analog-stereo.monitor',
              'Monitor of Built-in Analog Stereo')), isTrue);
      expect(SystemAudioSources.isMonitor(
          _dev('alsa_input.pci-0000_00_1f.3.analog-stereo', 'Built-in Microphone')),
          isFalse);
      // Real PipeWire strings observed on .41 (see
      // docs/spaces-system-audio-linux.md). isMonitor matches these correctly;
      // the Linux gap is that libwebrtc never enumerates them, not the filter.
      expect(SystemAudioSources.isMonitor(
          _dev('easyeffects_sink.monitor', 'Monitor of EasyEffects Sink')),
          isTrue);
      expect(SystemAudioSources.isMonitor(
          _dev('easyeffects_source', 'EasyEffects Source')), isFalse);
    });

    test('monitors filters to only monitor inputs, preserving order', () {
      final list = [
        _dev('mic1', 'Built-in Microphone'),
        _dev('sink.a.monitor', 'Monitor of A'),
        _dev('sink.b.monitor', 'Monitor of B'),
      ];
      final mons = SystemAudioSources.monitors(list);
      expect(mons.map((d) => d.deviceId), ['sink.a.monitor', 'sink.b.monitor']);
    });

    test('autoSelect prefers the analog/built-in monitor', () {
      final list = [
        _dev('sink.hdmi.monitor', 'Monitor of HDMI'),
        _dev('sink.analog-stereo.monitor', 'Monitor of Built-in Analog Stereo'),
      ];
      expect(SystemAudioSources.autoSelect(list)!.deviceId,
          'sink.analog-stereo.monitor');
    });

    test('autoSelect returns null when there is no monitor', () {
      expect(SystemAudioSources.autoSelect([_dev('mic1', 'Mic')]), isNull);
    });

    // ── Web / browser system-audio candidates ────────────────────────────
    //
    // On web the browser NEVER exposes a PulseAudio monitor: Chromium filters
    // monitor sources out of enumerateDevices, and web deviceIds are hashed
    // opaque strings that can never end in ".monitor". Verified live on .41
    // via CDP against Brave 150 (see docs/spaces-system-audio-linux.md). So
    // isMonitor/monitors are structurally empty on web, and the only usable
    // system-audio device is a REAL capture device fed by desktop audio: an
    // snd-aloop input or a PipeWire virtual source.

    test('isLoopbackCapture detects real loopback / virtual capture devices',
        () {
      expect(
          SystemAudioSources.isLoopbackCapture(
              _dev('2fa3e671e30e', 'Loopback Analog Stereo')),
          isTrue);
      expect(
          SystemAudioSources.isLoopbackCapture(_dev(
              'alsa_input.platform-snd_aloop.0.analog-stereo',
              'Loopback Analog Stereo')),
          isTrue);
      expect(
          SystemAudioSources.isLoopbackCapture(
              _dev('kodi_cast', 'Kodi Cast (Virtual Source)')),
          isTrue);
    });

    test('isLoopbackCapture NEVER matches a physical microphone', () {
      // Guards the exact regression the class doc warns about: feeding a mic
      // in as "system audio" silently re-captures the microphone under a
      // system-audio label and recreates the echo/blend bug.
      for (final mic in [
        _dev('956439f673df', 'Built-in Audio Analog Stereo'),
        _dev('9868cb30845c', 'Easy Effects Source'),
        _dev('default', 'Default'),
        _dev('alsa_input.pci-0000_00_1f.3.analog-stereo', 'Built-in Microphone'),
        _dev('easyeffects_source', 'EasyEffects Source'),
        _dev('usb-headset', 'Yeti Stereo Microphone'),
      ]) {
        expect(SystemAudioSources.isLoopbackCapture(mic), isFalse,
            reason: '${mic.label} must not be treated as system audio');
      }
    });

    test('candidates includes monitors AND loopback captures, in order', () {
      final list = [
        _dev('mic1', 'Built-in Microphone'),
        _dev('sink.a.monitor', 'Monitor of A'),
        _dev('aloop', 'Loopback Analog Stereo'),
      ];
      expect(SystemAudioSources.candidates(list).map((d) => d.deviceId),
          ['sink.a.monitor', 'aloop']);
    });

    test('autoSelect still prefers a monitor when one exists (native path)',
        () {
      final list = [
        _dev('aloop', 'Loopback Analog Stereo'),
        _dev('sink.analog-stereo.monitor', 'Monitor of Built-in Analog Stereo'),
      ];
      expect(SystemAudioSources.autoSelect(list)!.deviceId,
          'sink.analog-stereo.monitor');
    });

    test(
        'autoSelect picks the loopback device on the LIVE Brave/.41 device list',
        () {
      // Verbatim enumerateDevices() output captured over CDP from the Spaces
      // page in Brave on .41 while the blended-audio bug was reproducing.
      // Before the fix autoSelect returned null here, so the panel passed
      // systemAudioDeviceId: null and startScreenShareSystemAudio never ran,
      // leaving the microphone as the only published audio track.
      final live = [
        _dev('default', 'Default'),
        _dev('956439f673df', 'Built-in Audio Analog Stereo'),
        _dev('2fa3e671e30e', 'Loopback Analog Stereo'),
        _dev('9868cb30845c', 'Easy Effects Source'),
      ];
      expect(SystemAudioSources.monitors(live), isEmpty);
      expect(SystemAudioSources.autoSelect(live)!.label,
          'Loopback Analog Stereo');
    });

    test('autoSelect picks the cast device on the POST-FIX Brave/.41 list', () {
      // Verbatim enumerateDevices() output captured over CDP after the .41
      // routing was rebuilt (Kodi -> snd-aloop -> a source bound to the PAIRED
      // loopback device hw:Loopback,1,0, exported as "Kodi-Cast-Loopback").
      // The description is deliberately space-free: PipeWire's pactl truncates
      // module property values at the first whitespace, and on web the label is
      // the ONLY thing this class can match on, since deviceIds are hashed.
      final live = [
        _dev('default', 'Default'),
        _dev('956439f673df', 'Built-in Audio Analog Stereo'),
        _dev('9868cb30845c', 'Easy Effects Source'),
        _dev('c41d0a9b77e2', 'Kodi-Cast-Loopback'),
      ];
      expect(SystemAudioSources.autoSelect(live)!.label, 'Kodi-Cast-Loopback');
      // ...and the mic chain is never a candidate.
      expect(SystemAudioSources.candidates(live).map((d) => d.label),
          ['Kodi-Cast-Loopback']);
    });

    test('autoSelect returns null when nothing can carry system audio', () {
      expect(
          SystemAudioSources.autoSelect(
              [_dev('mic1', 'Mic'), _dev('956439f673df', 'Built-in Audio Analog Stereo')]),
          isNull);
    });

    test('captureOptions turns all voice processing off', () {
      final o = SystemAudioSources.captureOptions('sink.a.monitor');
      expect(o.deviceId, 'sink.a.monitor');
      expect(o.echoCancellation, isFalse);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
    });
  });
}
