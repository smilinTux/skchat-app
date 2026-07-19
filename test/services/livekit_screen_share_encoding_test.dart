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

  // DECOUPLE: the AVSYNC-fix custom stream:'screenshare' name (previously
  // shared by the screen-share VIDEO publish and the system-audio publish)
  // is dropped now that system audio publishes as its own distinct
  // TrackSource.screenShareAudio (see LiveKitCallService.
  // startScreenShareSystemAudio). buildStreamId (utils.dart:647) gives
  // screenShareVideo and screenShareAudio DIFFERENT fixed suffixes, so
  // keeping a shared custom name would make the two literal stream ids
  // diverge; PublishOptions.stream's own doc comment says the server pairs
  // screen_share + screen_share_audio by DEFAULT when no custom stream name
  // is given, so both sides now rely on that default instead.
  group('screen-share video + system-audio grouping (lip-sync)', () {
    test('screenSharePublishOptionsFor sets no custom stream name for any '
        'tier (relies on the SDK/server default pairing)', () {
      for (final tier in ScreenShareFrameRate.values) {
        final opts = LiveKitCallService.screenSharePublishOptionsFor(tier);
        expect(opts.stream, isNull, reason: 'tier=$tier');
      }
    });

    test('screenShareAudioPublishOptions also sets no custom stream name',
        () {
      final audioOpts = LiveKitCallService.screenShareAudioPublishOptions();
      expect(audioOpts.stream, isNull);
    });

    test('dropping the stream name does not disturb the M8 encoding tuning '
        '(maxBitrate/framerate/degradation, simulcast off)', () {
      final opts = LiveKitCallService.screenSharePublishOptionsFor(
        ScreenShareFrameRate.standard,
      );

      expect(opts.screenShareEncoding!.maxFramerate, 30);
      expect(opts.screenShareEncoding!.maxBitrate, 4 * 1000 * 1000);
      expect(opts.simulcast, isFalse);
      expect(
        opts.degradationPreference,
        DegradationPreference.maintainFramerate,
      );
      expect(opts.name, VideoPublishOptions.defaultScreenShareName);
    });
  });

  // REGRESSION (M8 review): the RoomOptions the service connects with must
  // NOT carry screen-share publish tuning as the room-wide video default.
  // The SDK routes any video publish that passes no explicit options through
  // RoomOptions.defaultVideoPublishOptions (publishVideoTrack,
  // src/participant/local.dart:207-208), and this app publishes CAMERA
  // tracks via bare setCameraEnabled(true) (conf_screen, livekit_call_screen,
  // call_provider). A screen-share-tuned room default would therefore leak
  // simulcast-off / maintainFramerate / the "screenshare" track name onto
  // camera publishes. Screen-share options must travel ONLY with the explicit
  // publish in setScreenShareEnabled.
  group('buildRoomOptions (camera path must stay untouched)', () {
    test('defaultVideoPublishOptions is the plain SDK default: simulcast on, '
        'no forced encoding, no degradation override, no track name', () {
      final opts = LiveKitCallService.buildRoomOptions();
      final videoDefaults = opts.defaultVideoPublishOptions;

      expect(videoDefaults.simulcast, isTrue,
          reason: 'camera simulcast must stay enabled');
      expect(videoDefaults.videoEncoding, isNull,
          reason: 'camera encoding must stay SDK-computed');
      expect(videoDefaults.screenShareEncoding, isNull,
          reason: 'screen-share encoding must not ride the room default');
      expect(videoDefaults.degradationPreference, isNull,
          reason: 'camera must keep the SDK default degradation policy');
      expect(videoDefaults.name, isNull,
          reason: 'camera tracks must not be named "screenshare"');
    });

    test('screen-share capture default stays pinned to the standard tier '
        '(explicit non-null maxFrameRate double, ee933f5 guard)', () {
      final opts = LiveKitCallService.buildRoomOptions();
      final capture = opts.defaultScreenShareCaptureOptions;

      expect(capture.maxFrameRate, 30.0);
      expect(capture.params, VideoParametersPresets.screenShareH1080FPS30);
    });

    test('room defaults differ from the explicit screen-share publish '
        'options on every screen-share-specific field', () {
      final roomDefault =
          LiveKitCallService.buildRoomOptions().defaultVideoPublishOptions;
      final sharePublish = LiveKitCallService.screenSharePublishOptionsFor(
        ScreenShareFrameRate.standard,
      );

      expect(roomDefault.simulcast, isNot(sharePublish.simulcast));
      expect(roomDefault.screenShareEncoding,
          isNot(sharePublish.screenShareEncoding));
      expect(roomDefault.degradationPreference,
          isNot(sharePublish.degradationPreference));
      expect(roomDefault.name, isNot(sharePublish.name));
    });
  });
}
