import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/services/livekit_call_service.dart';

class _MockRoom extends Mock implements Room {}

class _MockLocalParticipant extends Mock implements LocalParticipant {}

class _MockRemoteParticipant extends Mock implements RemoteParticipant {}

// V1: "who is speaking, and how loudly" needs to be a real, event-driven
// signal. Before this change LiveKitParticipantSnapshot only carried the
// bool isSpeaking, LiveKit's own threshold on a continuous level, and
// _bindRoomListeners never bound ActiveSpeakersChangedEvent, so the flag
// only ever refreshed when some UNRELATED room event happened to trigger a
// re-snapshot. See the doc comments on LiveKitParticipantSnapshot.audioLevel
// and on the ActiveSpeakersChangedEvent binding in _bindRoomListeners
// (lib/services/livekit_call_service.dart) for the installed livekit_client
// 2.5.0+hotfix.3 source evidence: Room keeps Room.activeSpeakers sorted by
// Participant.audioLevel descending (src/core/room.dart:760).
void main() {
  group('LiveKitParticipantSnapshot.audioLevel', () {
    test('defaults to 0 when not supplied', () {
      const snap = LiveKitParticipantSnapshot(
        identity: 'chef',
        isLocal: true,
        isMuted: false,
        isCameraEnabled: false,
      );
      expect(snap.audioLevel, 0.0);
    });

    test(
        "currentParticipants carries the LOCAL participant's continuous "
        'audioLevel alongside (not instead of) the isSpeaking threshold',
        () async {
      final svc = LiveKitCallService();
      final room = _MockRoom();
      final local = _MockLocalParticipant();
      when(() => local.identity).thenReturn('chef');
      when(() => local.isMicrophoneEnabled()).thenReturn(true);
      when(() => local.isCameraEnabled()).thenReturn(false);
      when(() =>
              local.getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => local.permissions)
          .thenReturn(const ParticipantPermissions());
      when(() => local.metadata).thenReturn(null);
      when(() => local.isSpeaking).thenReturn(true);
      when(() => local.audioLevel).thenReturn(0.73);
      when(() => local.connectionQuality)
          .thenReturn(ConnectionQuality.excellent);
      when(() => room.localParticipant).thenReturn(local);
      when(() => room.remoteParticipants)
          .thenReturn(UnmodifiableMapView<String, RemoteParticipant>(const {}));
      svc.debugRoom = room;

      final snap = svc.currentParticipants.single;

      expect(snap.audioLevel, 0.73);
      expect(snap.isSpeaking, isTrue);

      await svc.dispose();
    });

    test("currentParticipants carries a REMOTE participant's audioLevel",
        () async {
      final svc = LiveKitCallService();
      final room = _MockRoom();
      final remote = _MockRemoteParticipant();
      when(() => remote.identity).thenReturn('lumina');
      when(() => remote.isMicrophoneEnabled()).thenReturn(true);
      when(() => remote.isCameraEnabled()).thenReturn(false);
      when(() => remote
              .getTrackPublicationBySource(TrackSource.screenShareVideo))
          .thenReturn(null);
      when(() => remote.permissions)
          .thenReturn(const ParticipantPermissions());
      when(() => remote.metadata).thenReturn(null);
      when(() => remote.isSpeaking).thenReturn(false);
      when(() => remote.audioLevel).thenReturn(0.05);
      when(() => remote.connectionQuality).thenReturn(ConnectionQuality.good);
      when(() => room.localParticipant).thenReturn(null);
      when(() => room.remoteParticipants).thenReturn(
          UnmodifiableMapView<String, RemoteParticipant>(
              {'lumina': remote}));
      svc.debugRoom = room;

      final snap = svc.currentParticipants.single;

      expect(snap.audioLevel, 0.05);

      await svc.dispose();
    });
  });

  group(
      'ActiveSpeakersChangedEvent binding (makes speaking state '
      'event-driven, not incidental)', () {
    test(
        'binding fires an EXTRA participants emission beyond the generic '
        "Room ChangeNotifier relay: Room's own constructor calls "
        'notifyListeners() on every RoomEvent with no filtering (verified '
        'against the installed SDK source), so a bare "did an emission '
        'happen" assertion cannot tell this specific binding apart from '
        'that always-present fallback path. Only an exact emission count '
        'can: one from the fallback, plus one more from '
        '..on<ActiveSpeakersChangedEvent>(_emitParticipants). Delete just '
        'that binding line and this drops back to 1 and fails.', () async {
      final svc = LiveKitCallService();
      final room = Room();
      svc.debugRoom = room;
      svc.debugBindRoomListeners();

      final emissions = <List<LiveKitParticipantSnapshot>>[];
      final sub = svc.participants.listen(emissions.add);

      room.events.streamCtrl
          .add(const ActiveSpeakersChangedEvent(speakers: []));
      await Future<void>.delayed(Duration.zero);

      expect(emissions.length, 2);

      await sub.cancel();
      await svc.dispose();
    });
  });
}
