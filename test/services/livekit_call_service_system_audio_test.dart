import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _FakeLocalTrack extends Mock implements LocalTrack {}

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
  });
}
