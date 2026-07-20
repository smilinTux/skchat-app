import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _FakeLocalParticipant extends Mock implements LocalParticipant {}

class _FakeLocalVideoTrack extends Mock implements LocalVideoTrack {}

class _FakeLocalTrackPublication extends Mock
    implements LocalTrackPublication<LocalVideoTrack> {}

class _FakeMediaStreamTrack extends Mock implements rtc.MediaStreamTrack {}

// CAM: Spaces "Go live" with camera (front/back). LiveKitCallService.
// setCameraEnabled/setScreenShareEnabled already publish/tear down; this
// covers the two additions the feature needs: an optional CameraPosition on
// setCameraEnabled (front default, additive so every existing bare
// setCameraEnabled(true) caller, e.g. conf_screen.dart /
// livekit_call_screen.dart, is unaffected), and the camera/screen mutual
// exclusion (camera XOR screen: only one live video source at a time).
void main() {
  setUpAll(() {
    registerFallbackValue(const CameraCaptureOptions());
    registerFallbackValue(_FakeMediaStreamTrack());
  });

  group('setCameraEnabled facing', () {
    test('enabling with no explicit facing publishes front (the default)',
        () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(false);
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => lp.setCameraEnabled(any(),
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .thenAnswer((_) async => null);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(true);

      final captured = verify(() => lp.setCameraEnabled(true,
              cameraCaptureOptions: captureAny(named: 'cameraCaptureOptions')))
          .captured;
      final options = captured.single as CameraCaptureOptions;
      expect(options.cameraPosition, CameraPosition.front);
    });

    test('enabling with cameraPosition: back publishes back facing',
        () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(false);
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => lp.setCameraEnabled(any(),
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .thenAnswer((_) async => null);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(true, cameraPosition: CameraPosition.back);

      final captured = verify(() => lp.setCameraEnabled(true,
              cameraCaptureOptions: captureAny(named: 'cameraCaptureOptions')))
          .captured;
      final options = captured.single as CameraCaptureOptions;
      expect(options.cameraPosition, CameraPosition.back);
    });

    test('setCameraEnabled(false) never touches the screen share',
        () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(true);
      when(() => lp.isCameraEnabled()).thenReturn(false);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(false);

      verifyNever(() => lp.setScreenShareEnabled(any(),
          captureScreenAudio: any(named: 'captureScreenAudio'),
          screenShareCaptureOptions:
              any(named: 'screenShareCaptureOptions')));
    });

    test('setCameraEnabled(false) UNPUBLISHES the camera track (does not '
        'call the SDK setCameraEnabled(false), which only mutes)', () async {
      // Root cause of the frozen-video / next-share-blocked bug: the SDK's
      // LocalParticipant.setCameraEnabled(false) mutes-not-unpublishes for
      // TrackSource.camera, leaving a muted-but-still-published track that
      // viewers keep rendering. The fix mirrors the screen-share stop path
      // (which the SDK itself unpublishes) by calling removePublishedTrack
      // directly.
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      final pub = _FakeLocalTrackPublication();
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.sid).thenReturn('TR_camera_9');
      when(() => lp.removePublishedTrack(any()))
          .thenAnswer((_) async {});
      when(() => lp.isCameraEnabled()).thenReturn(false);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(false);

      verify(() => lp.removePublishedTrack('TR_camera_9')).called(1);
      verifyNever(() => lp.setCameraEnabled(false,
          cameraCaptureOptions: any(named: 'cameraCaptureOptions')));
    });

    test('setCameraEnabled(false) with no camera publication is a safe '
        'no-op', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => lp.isCameraEnabled()).thenReturn(false);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(false);

      verifyNever(() => lp.removePublishedTrack(any()));
    });

    test('setCameraEnabled(true) still calls the SDK setCameraEnabled(true) '
        '(enable path unchanged)', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(false);
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.setCameraEnabled(any(),
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .thenAnswer((_) async => null);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(true);

      verify(() => lp.setCameraEnabled(true,
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .called(1);
      verifyNever(() => lp.removePublishedTrack(any()));
    });
  });

  group('camera XOR screen: video mutual exclusion', () {
    test('going live on camera stops an active screen share first',
        () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(true);
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => lp.setScreenShareEnabled(false,
              captureScreenAudio: any(named: 'captureScreenAudio'),
              screenShareCaptureOptions:
                  any(named: 'screenShareCaptureOptions')))
          .thenAnswer((_) async => null);
      when(() => lp.setCameraEnabled(any(),
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .thenAnswer((_) async => null);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(true);

      verify(() => lp.setScreenShareEnabled(false,
              captureScreenAudio: any(named: 'captureScreenAudio'),
              screenShareCaptureOptions:
                  any(named: 'screenShareCaptureOptions')))
          .called(1);
      verify(() => lp.setCameraEnabled(true,
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .called(1);
    });

    test('going live on camera with no active screen share never calls '
        'setScreenShareEnabled', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(false);
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => lp.setCameraEnabled(any(),
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .thenAnswer((_) async => null);
      svc.debugLocalParticipant = lp;

      await svc.setCameraEnabled(true);

      verifyNever(() => lp.setScreenShareEnabled(any(),
          captureScreenAudio: any(named: 'captureScreenAudio'),
          screenShareCaptureOptions:
              any(named: 'screenShareCaptureOptions')));
    });

    test('stopCameraForScreenShare stops an active camera by unpublishing '
        'it (not muting)', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      final pub = _FakeLocalTrackPublication();
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.sid).thenReturn('TR_camera_1');
      when(() => lp.removePublishedTrack(any()))
          .thenAnswer((_) async {});
      svc.debugLocalParticipant = lp;

      await svc.stopCameraForScreenShare();

      verify(() => lp.removePublishedTrack('TR_camera_1')).called(1);
      verifyNever(() => lp.setCameraEnabled(false,
          cameraCaptureOptions: any(named: 'cameraCaptureOptions')));
    });

    test('stopCameraForScreenShare is a safe no-op when no camera is live',
        () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isCameraEnabled()).thenReturn(false);
      svc.debugLocalParticipant = lp;

      await svc.stopCameraForScreenShare();

      verifyNever(() => lp.setCameraEnabled(any(),
          cameraCaptureOptions: any(named: 'cameraCaptureOptions')));
      verifyNever(() => lp.removePublishedTrack(any()));
    });

    test('stopScreenShareForCamera stops an active screen share', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(true);
      when(() => lp.setScreenShareEnabled(false,
              captureScreenAudio: any(named: 'captureScreenAudio'),
              screenShareCaptureOptions:
                  any(named: 'screenShareCaptureOptions')))
          .thenAnswer((_) async => null);
      svc.debugLocalParticipant = lp;

      await svc.stopScreenShareForCamera();

      verify(() => lp.setScreenShareEnabled(false,
              captureScreenAudio: any(named: 'captureScreenAudio'),
              screenShareCaptureOptions:
                  any(named: 'screenShareCaptureOptions')))
          .called(1);
    });

    test(
        'stopScreenShareForCamera is a safe no-op when no screen share is '
        'live', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.isScreenShareEnabled()).thenReturn(false);
      svc.debugLocalParticipant = lp;

      await svc.stopScreenShareForCamera();

      verifyNever(() => lp.setScreenShareEnabled(any(),
          captureScreenAudio: any(named: 'captureScreenAudio'),
          screenShareCaptureOptions:
              any(named: 'screenShareCaptureOptions')));
    });
  });

  group('switchCameraPosition', () {
    test('with no camera track live yet, publishes directly on the '
        'requested facing (delegates to setCameraEnabled)', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(null);
      when(() => lp.isScreenShareEnabled()).thenReturn(false);
      when(() => lp.isCameraEnabled()).thenReturn(true);
      when(() => lp.setCameraEnabled(any(),
              cameraCaptureOptions: any(named: 'cameraCaptureOptions')))
          .thenAnswer((_) async => null);
      svc.debugLocalParticipant = lp;

      await svc.switchCameraPosition(CameraPosition.back);

      final captured = verify(() => lp.setCameraEnabled(true,
              cameraCaptureOptions: captureAny(named: 'cameraCaptureOptions')))
          .captured;
      final options = captured.single as CameraCaptureOptions;
      expect(options.cameraPosition, CameraPosition.back);
    });

    test('with no local participant, is a safe no-op', () async {
      final svc = LiveKitCallService();
      // No room joined, so _localParticipant is null: the method must guard.
      await svc.switchCameraPosition(CameraPosition.back);
    });

    // The published-camera branch exercises livekit_client's own
    // LocalVideoTrackExt.setCameraPosition extension (video.dart:276),
    // which calls restartTrack + replaceTrackForMultiCodecSimulcast on the
    // SAME track (a "fast flip", no unpublish/republish), then updates
    // currentOptions. Every member it touches is a real (mockable) member of
    // LocalVideoTrack/LocalTrack, so a Mock reaches this real extension body
    // without ever touching the SDK's actual capture/replace-track native
    // code (those calls are themselves mocked, stubbed to no-ops below).
    test('with a camera track already published, flips it in place '
        '(restarts the SAME track, does not republish)', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      final pub = _FakeLocalTrackPublication();
      final track = _FakeLocalVideoTrack();
      final mediaTrack = _FakeMediaStreamTrack();
      when(() => lp.getTrackPublicationBySource(TrackSource.camera))
          .thenReturn(pub);
      when(() => pub.track).thenReturn(track);
      when(() => track.currentOptions)
          .thenReturn(const CameraCaptureOptions(cameraPosition: CameraPosition.front));
      when(() => track.mediaStreamTrack).thenReturn(mediaTrack);
      when(() => track.restartTrack(any())).thenAnswer((_) async {});
      // replaceTrackForMultiCodecSimulcast (called by the real
      // setCameraPosition extension body after restartTrack) is ITSELF an
      // extension method (LocalVideoTrackExt), so it cannot be stubbed away
      // like restartTrack above; its real body runs for real. Stubbing the
      // one real (mockable) field it touches, simulcastCodecs, to an empty
      // map makes that real body a harmless no-op (nothing to iterate).
      when(() => track.simulcastCodecs).thenReturn({});
      svc.debugLocalParticipant = lp;

      await svc.switchCameraPosition(CameraPosition.back);

      final captured =
          verify(() => track.restartTrack(captureAny())).captured;
      final newOptions = captured.single as CameraCaptureOptions;
      expect(newOptions.cameraPosition, CameraPosition.back);
      // The flip goes through the EXISTING track, never a fresh publish.
      verifyNever(() => lp.setCameraEnabled(any(),
          cameraCaptureOptions: any(named: 'cameraCaptureOptions')));
    });
  });
}
