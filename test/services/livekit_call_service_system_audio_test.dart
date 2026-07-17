import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/livekit_call_service.dart';

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
}
