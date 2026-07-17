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

    test('captureOptions turns all voice processing off', () {
      final o = SystemAudioSources.captureOptions('sink.a.monitor');
      expect(o.deviceId, 'sink.a.monitor');
      expect(o.echoCancellation, isFalse);
      expect(o.noiseSuppression, isFalse);
      expect(o.autoGainControl, isFalse);
    });
  });
}
