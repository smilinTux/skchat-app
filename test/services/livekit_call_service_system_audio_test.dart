import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _FakeLocalTrack extends Mock implements LocalTrack {}

class _FakeLocalParticipant extends Mock implements LocalParticipant {}

void main() {
  test('isSharingSystemAudio is false before any share', () {
    final svc = LiveKitCallService();
    expect(svc.isSharingSystemAudio, isFalse);
  });

  test('stopScreenShareSystemAudio is a safe no-op when nothing is shared', () async {
    final svc = LiveKitCallService();
    await svc.stopScreenShareSystemAudio();
    expect(svc.isSharingSystemAudio, isFalse);
  });

  test('start with no local participant does not throw and stays not-sharing',
      () async {
    final svc = LiveKitCallService();
    // No room joined, so _localParticipant is null: the method must guard.
    await svc.startScreenShareSystemAudio('sink.a.monitor');
    expect(svc.isSharingSystemAudio, isFalse);
  });

  // IF1: startScreenShareSystemAudio() enforces "at most one microphone-
  // source publication" by disabling the real mic through setMicEnabled(),
  // NOT a raw lp.setMicrophoneEnabled() call, so that internal flip is
  // observable on micEnabledChanges the same as an explicit caller toggle.
  // A no-room service has no local participant to actually flip, so this
  // exercises the seam at the level that IS unit-testable without a live
  // LiveKit room/SDK: setMicEnabled() itself must emit regardless of
  // whether a local participant exists yet, mirroring how _emitParticipants
  // already fires unconditionally.
  test('setMicEnabled emits on micEnabledChanges for every call, even with '
      'no room', () async {
    final svc = LiveKitCallService();
    final events = <bool>[];
    final sub = svc.micEnabledChanges.listen(events.add);

    await svc.setMicEnabled(false);
    await svc.setMicEnabled(true);
    // Let the broadcast stream's async dispatch settle before asserting.
    await Future<void>.delayed(Duration.zero);

    expect(events, [false, true]);
    await sub.cancel();
  });

  // M1: externalMuteEvents is the "server-initiated mute" signal (a host
  // force-mute via MuteRoomTrackRequest, reconciled from the raw LiveKit
  // TrackMutedEvent in _bindRoomListeners / _reconcileExternalMicMute). That
  // reconciliation needs a live Room/Participant to exercise the SDK event
  // path, which is not available in a plain unit test (no LiveKit server),
  // see the widget-level M1 group in space_room_screen_test.dart for the
  // observable-behavior coverage. This is the unit-level smoke check: the
  // stream exists, is safe to listen to with no room ever joined, and
  // dispose() closes it cleanly alongside the other controllers.
  test('externalMuteEvents stream exists and dispose closes it safely',
      () async {
    final svc = LiveKitCallService();
    final events = <void>[];
    final sub = svc.externalMuteEvents.listen(events.add);
    await svc.dispose();
    expect(events, isEmpty);
    await sub.cancel();
  });

  // Source-closed / OS-stop teardown: the operator on native Linux stops the
  // share via the desktop's own "Stop sharing" indicator (or the captured
  // window closes), NOT the app button. The SDK auto-unpublishes the local
  // screen-share VIDEO and emits LocalTrackUnpublishedEvent, but the
  // device-captured PulseAudio system-audio monitor is a separate track the
  // SDK does not own. Before the fix that monitor kept streaming (the Space
  // kept broadcasting Kodi audio after the share visibly ended). The video
  // unpublish must now tear the monitor down too, tying its lifecycle to the
  // screen-share video for EVERY stop path. See handleLocalTrackUnpublished.
  group('screen-share video unpublish tears down the system-audio monitor', () {
    test('screenShareVideo unpublish (OS stop / source closed) stops and '
        'clears the monitor track', () async {
      final svc = LiveKitCallService();
      final monitor = _FakeLocalTrack();
      when(() => monitor.sid).thenReturn(null);
      when(() => monitor.stop()).thenAnswer((_) async => true);
      // Simulate an in-flight system-audio share (started when the host went
      // live with system audio ON; no room needed to drive the teardown seam).
      svc.debugSystemAudioTrack = monitor;
      expect(svc.isSharingSystemAudio, isTrue);

      await svc.handleLocalTrackUnpublished(TrackSource.screenShareVideo);

      expect(svc.isSharingSystemAudio, isFalse,
          reason: 'the monitor track must be torn down with the share');
      verify(() => monitor.stop()).called(1);
    });

    test('an unrelated local track unpublish (e.g. camera) leaves the monitor '
        'untouched', () async {
      final svc = LiveKitCallService();
      final monitor = _FakeLocalTrack();
      when(() => monitor.sid).thenReturn(null);
      when(() => monitor.stop()).thenAnswer((_) async => true);
      svc.debugSystemAudioTrack = monitor;

      await svc.handleLocalTrackUnpublished(TrackSource.camera);

      expect(svc.isSharingSystemAudio, isTrue);
      verifyNever(() => monitor.stop());
    });

    test('screenShareVideo unpublish with no system audio is a safe no-op',
        () async {
      final svc = LiveKitCallService();
      // No monitor track set: must not throw, stays not-sharing.
      await svc.handleLocalTrackUnpublished(TrackSource.screenShareVideo);
      expect(svc.isSharingSystemAudio, isFalse);
    });

    // The operator's actual complaint, end to end: after the OS-level stop
    // tore the share down, tapping Unmute must publish the genuine VOICE mic
    // (setMicrophoneEnabled on the participant), NOT resurrect or unmute the
    // monitor, and micEnabledChanges must carry the flip so the control bar
    // updates. X model: nothing auto-unmutes; only the explicit tap emits.
    test('mic restore after source-closed stop: Unmute publishes the voice '
        'mic and emits micEnabledChanges true, monitor stays dead', () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.removePublishedTrack(any(), notify: any(named: 'notify')))
          .thenAnswer((_) async {});
      when(() => lp.setMicrophoneEnabled(any(),
              audioCaptureOptions: any(named: 'audioCaptureOptions')))
          .thenAnswer((_) async => null);
      final monitor = _FakeLocalTrack();
      when(() => monitor.sid).thenReturn('TR_monitor');
      when(() => monitor.stop()).thenAnswer((_) async => true);
      svc.debugLocalParticipant = lp;
      svc.debugSystemAudioTrack = monitor;

      final micEvents = <bool>[];
      final sub = svc.micEnabledChanges.listen(micEvents.add);

      // OS "Stop sharing" / source closed: the SDK unpublishes the share
      // video; the app handler tears the monitor down. No mic emission here
      // (the teardown must not look like an unmute or a mute to the UI).
      await svc.handleLocalTrackUnpublished(TrackSource.screenShareVideo);
      expect(svc.isSharingSystemAudio, isFalse);

      // The operator taps Unmute.
      await svc.setMicEnabled(true);
      await Future<void>.delayed(Duration.zero);

      // Genuine voice-mic publish on the participant, exactly once.
      verify(() => lp.setMicrophoneEnabled(true,
          audioCaptureOptions: any(named: 'audioCaptureOptions'))).called(1);
      // Observable to UI state, and ONLY from the explicit tap.
      expect(micEvents, [true]);
      // Monitor was stopped exactly once (the teardown) and never touched
      // again: the Unmute did not route to the monitor track. The teardown
      // also unpublished the monitor publication exactly once; beyond that
      // and the voice-mic publish, the participant saw nothing.
      verify(() => monitor.stop()).called(1);
      verify(() => lp.removePublishedTrack(any(), notify: any(named: 'notify')))
          .called(1);
      verifyNoMoreInteractions(lp);
      expect(svc.isSharingSystemAudio, isFalse);
      await sub.cancel();
    });

    // Explicit app-button stop, then the SDK's own follow-up unpublish event
    // for the removed share video (the SDK emits LocalTrackUnpublishedEvent
    // from removePublishedTrack). The teardown must run once on the explicit
    // stop and the follow-up event must be an idempotent no-op: no second
    // monitor.stop(), no second removePublishedTrack, and no micEnabledChanges
    // emission from any of it (a share stop is not a mute/unmute).
    test('explicit stop tears down once; the follow-up unpublish event does '
        'not double-teardown and emits no spurious micEnabledChanges',
        () async {
      final svc = LiveKitCallService();
      final lp = _FakeLocalParticipant();
      when(() => lp.removePublishedTrack(any(), notify: any(named: 'notify')))
          .thenAnswer((_) async {});
      when(() => lp.setScreenShareEnabled(any(),
              captureScreenAudio: any(named: 'captureScreenAudio'),
              screenShareCaptureOptions:
                  any(named: 'screenShareCaptureOptions')))
          .thenAnswer((_) async => null);
      final monitor = _FakeLocalTrack();
      when(() => monitor.sid).thenReturn('TR_monitor');
      when(() => monitor.stop()).thenAnswer((_) async => true);
      svc.debugLocalParticipant = lp;
      svc.debugSystemAudioTrack = monitor;

      final micEvents = <bool>[];
      final sub = svc.micEnabledChanges.listen(micEvents.add);

      // App-button stop: monitor torn down with the share.
      await svc.setScreenShareEnabled(false);
      expect(svc.isSharingSystemAudio, isFalse);

      // The SDK's own unpublish event for the share video arrives next.
      await svc.handleLocalTrackUnpublished(TrackSource.screenShareVideo);
      await Future<void>.delayed(Duration.zero);

      // Exactly ONE teardown across both: one monitor stop, one unpublish of
      // the monitor publication, one SDK-helper share disable.
      verify(() => monitor.stop()).called(1);
      verify(() => lp.removePublishedTrack(any(), notify: any(named: 'notify')))
          .called(1);
      verify(() => lp.setScreenShareEnabled(false,
              captureScreenAudio: any(named: 'captureScreenAudio'),
              screenShareCaptureOptions:
                  any(named: 'screenShareCaptureOptions')))
          .called(1);
      verifyNoMoreInteractions(lp);
      // A share stop is not a mute/unmute: nothing on micEnabledChanges.
      expect(micEvents, isEmpty);
      expect(svc.isSharingSystemAudio, isFalse);
      await sub.cancel();
    });
  });
}
