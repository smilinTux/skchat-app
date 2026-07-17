import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:skchat/services/livekit_call_service.dart';

// M8: screen-share is slow / glitchy for LAN viewers on motion content
// (Kodi/video playback through Spaces on native Linux). This asserts the
// tuned publish + capture options that setScreenShareEnabled() actually
// passes to the SDK, for both the default (standard) path and the
// lowBandwidth fallback preset. See the doc comment on
// LiveKitCallService.screenSharePublishOptionsFor for the SDK-source
// rationale behind every number asserted here.
void main() {
  group('screenSharePublishOptionsFor', () {
    test('standard tier: 1080p30 at the SDK\'s own 4 Mbps preset ceiling, '
        'no simulcast, framerate-preserving degradation', () {
      final opts = LiveKitCallService.screenSharePublishOptionsFor(
        ScreenShareFrameRate.standard,
      );

      expect(opts.screenShareEncoding, isNotNull);
      expect(opts.screenShareEncoding!.maxFramerate, 30);
      // Matches VideoParametersPresets.screenShareH1080FPS30 exactly.
      expect(opts.screenShareEncoding!.maxBitrate, 4 * 1000 * 1000);
      expect(opts.simulcast, isFalse);
      // The SDK's own screen-share default is maintainResolution
      // (LocalParticipant.getDefaultDegradationPreference); motion content
      // needs the opposite, so this must be explicit.
      expect(
        opts.degradationPreference,
        DegradationPreference.maintainFramerate,
      );
      expect(opts.name, VideoPublishOptions.defaultScreenShareName);
    });

    test('lowBandwidth tier: 1080p15 at the SDK\'s own 2.5 Mbps preset '
        'ceiling, same simulcast-off / framerate-preserving policy', () {
      final opts = LiveKitCallService.screenSharePublishOptionsFor(
        ScreenShareFrameRate.lowBandwidth,
      );

      expect(opts.screenShareEncoding, isNotNull);
      expect(opts.screenShareEncoding!.maxFramerate, 15);
      // Matches VideoParametersPresets.screenShareH1080FPS15 exactly.
      expect(opts.screenShareEncoding!.maxBitrate, 2500 * 1000);
      expect(opts.simulcast, isFalse);
      expect(
        opts.degradationPreference,
        DegradationPreference.maintainFramerate,
      );
    });
  });

  group('screenShareCaptureOptionsFor', () {
    test('standard tier captures at 30 fps with an explicit non-null double '
        '(native-desktop SIGABRT guard, see ee933f5)', () {
      final opts = LiveKitCallService.screenShareCaptureOptionsFor(
        ScreenShareFrameRate.standard,
      );

      expect(opts.maxFrameRate, 30.0);
      expect(opts.params, VideoParametersPresets.screenShareH1080FPS30);
    });

    test('lowBandwidth tier captures at 15 fps with an explicit non-null '
        'double', () {
      final opts = LiveKitCallService.screenShareCaptureOptionsFor(
        ScreenShareFrameRate.lowBandwidth,
      );

      expect(opts.maxFrameRate, 15.0);
      expect(opts.params, VideoParametersPresets.screenShareH1080FPS15);
    });

    test('forwards sourceId and captureScreenAudio through unchanged', () {
      final opts = LiveKitCallService.screenShareCaptureOptionsFor(
        ScreenShareFrameRate.standard,
        sourceId: 'screen:0:0',
        captureScreenAudio: true,
      );

      expect(opts.deviceId, 'screen:0:0');
      expect(opts.captureScreenAudio, isTrue);
    });

    test('capture and publish tiers stay in lockstep on framerate: a 30 fps '
        'publish ceiling is never paired with a 15 fps capture cap, and '
        'vice versa', () {
      for (final tier in ScreenShareFrameRate.values) {
        final capture = LiveKitCallService.screenShareCaptureOptionsFor(tier);
        final publish = LiveKitCallService.screenSharePublishOptionsFor(tier);
        expect(
          capture.maxFrameRate,
          publish.screenShareEncoding!.maxFramerate.toDouble(),
          reason: 'tier=$tier capture/publish framerate mismatch',
        );
      }
    });
  });
}
