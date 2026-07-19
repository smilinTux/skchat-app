import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/livekit_call_service.dart';

// X1: guest "invited to speak" prompt + host list freshness.
//
// Covers the two static metadata parsers (parseHandRaised /
// parseInvitedToStage, all 4 hand_raised x invited_to_stage combos) and the
// microtask-deferred re-emit mechanism added to defend against a remote
// participant's canPublish going stale on the host's roster (see the long
// doc comment on the ParticipantMetadataUpdatedEvent binding in
// _bindRoomListeners, lib/services/livekit_call_service.dart, for the
// installed livekit_client 2.5.0+hotfix.3 source evidence behind that fix).
void main() {
  group('LiveKitParticipantSnapshot.parseHandRaised', () {
    test('hand_raised true, invited_to_stage true', () {
      expect(
        LiveKitParticipantSnapshot.parseHandRaised(
            '{"hand_raised":true,"invited_to_stage":true}'),
        isTrue,
      );
    });

    test('hand_raised true, invited_to_stage false', () {
      expect(
        LiveKitParticipantSnapshot.parseHandRaised(
            '{"hand_raised":true,"invited_to_stage":false}'),
        isTrue,
      );
    });

    test('hand_raised false, invited_to_stage true', () {
      expect(
        LiveKitParticipantSnapshot.parseHandRaised(
            '{"hand_raised":false,"invited_to_stage":true}'),
        isFalse,
      );
    });

    test('hand_raised false, invited_to_stage false', () {
      expect(
        LiveKitParticipantSnapshot.parseHandRaised(
            '{"hand_raised":false,"invited_to_stage":false}'),
        isFalse,
      );
    });

    test('null / empty / malformed metadata all default to false', () {
      expect(LiveKitParticipantSnapshot.parseHandRaised(null), isFalse);
      expect(LiveKitParticipantSnapshot.parseHandRaised(''), isFalse);
      expect(LiveKitParticipantSnapshot.parseHandRaised('not json'), isFalse);
      expect(LiveKitParticipantSnapshot.parseHandRaised('[1,2,3]'), isFalse);
      expect(LiveKitParticipantSnapshot.parseHandRaised('{}'), isFalse);
    });
  });

  group('LiveKitParticipantSnapshot.parseInvitedToStage', () {
    test('invited_to_stage true, hand_raised true', () {
      expect(
        LiveKitParticipantSnapshot.parseInvitedToStage(
            '{"hand_raised":true,"invited_to_stage":true}'),
        isTrue,
      );
    });

    test('invited_to_stage true, hand_raised false', () {
      expect(
        LiveKitParticipantSnapshot.parseInvitedToStage(
            '{"hand_raised":false,"invited_to_stage":true}'),
        isTrue,
      );
    });

    test('invited_to_stage false, hand_raised true', () {
      expect(
        LiveKitParticipantSnapshot.parseInvitedToStage(
            '{"hand_raised":true,"invited_to_stage":false}'),
        isFalse,
      );
    });

    test('invited_to_stage false, hand_raised false', () {
      expect(
        LiveKitParticipantSnapshot.parseInvitedToStage(
            '{"hand_raised":false,"invited_to_stage":false}'),
        isFalse,
      );
    });

    test('null / empty / malformed metadata all default to false', () {
      expect(LiveKitParticipantSnapshot.parseInvitedToStage(null), isFalse);
      expect(LiveKitParticipantSnapshot.parseInvitedToStage(''), isFalse);
      expect(
          LiveKitParticipantSnapshot.parseInvitedToStage('not json'), isFalse);
      expect(
          LiveKitParticipantSnapshot.parseInvitedToStage('[1,2,3]'), isFalse);
      expect(LiveKitParticipantSnapshot.parseInvitedToStage('{}'), isFalse);
    });
  });

  group('X1 host-list freshness: metadata-change re-emit', () {
    test(
        'debugSimulateMetadataChange emits participants twice: nothing '
        'delivered synchronously (the broadcast controller defers to a '
        'microtask), then two emissions once the microtask queue drains',
        () async {
      final svc = LiveKitCallService();
      final emissions = <List<LiveKitParticipantSnapshot>>[];
      final sub = svc.participants.listen(emissions.add);

      svc.debugSimulateMetadataChange();
      // Nothing delivered yet: _participantsCtl is a broadcast
      // StreamController with the (default) sync:false dispatch, so both
      // .add() calls this triggers only SCHEDULE delivery, they don't
      // deliver inline.
      expect(emissions, isEmpty);

      // Drain the event loop (microtasks + the deferred second emit).
      await Future<void>.delayed(Duration.zero);

      expect(emissions.length, 2);

      await sub.cancel();
      await svc.dispose();
    });

    test('debugSimulateMetadataChange is a safe no-op shape with no room',
        () async {
      final svc = LiveKitCallService();
      // No live Room: currentParticipants degrades to [], both emissions
      // just carry an empty list. Asserts this never throws.
      svc.debugSimulateMetadataChange();
      await Future<void>.delayed(Duration.zero);
      await svc.dispose();
    });
  });

  // PERMFIX: a promoted speaker's own client only ever receives the publish
  // grant as a bare ParticipantPermissionsUpdatedEvent (see the long doc
  // comment on that binding in _bindRoomListeners): the metadata value is
  // unchanged, so ParticipantMetadataUpdatedEvent never fires for that
  // update, and canPublish went stale on the local snapshot until some
  // unrelated event forced a re-snapshot ("Raise hand" instead of
  // mute/unmute). _bindRoomListeners now binds
  // ParticipantPermissionsUpdatedEvent to the SAME re-emit path
  // (_onParticipantMetadataChanged) the metadata event already uses.
  // debugSimulatePermissionsChange fires that exact path without needing a
  // live Room/SDK connection, mirroring debugSimulateMetadataChange above.
  group('PERMFIX: permissions-updated re-emit (promoted-speaker freshness)',
      () {
    test(
        'debugSimulatePermissionsChange emits participants twice via the '
        'same re-emit path as the metadata event: nothing delivered '
        'synchronously, then two emissions once the microtask queue drains',
        () async {
      final svc = LiveKitCallService();
      final emissions = <List<LiveKitParticipantSnapshot>>[];
      final sub = svc.participants.listen(emissions.add);

      svc.debugSimulatePermissionsChange();
      expect(emissions, isEmpty);

      await Future<void>.delayed(Duration.zero);

      expect(emissions.length, 2);

      await sub.cancel();
      await svc.dispose();
    });

    test('debugSimulatePermissionsChange is a safe no-op shape with no room',
        () async {
      final svc = LiveKitCallService();
      svc.debugSimulatePermissionsChange();
      await Future<void>.delayed(Duration.zero);
      await svc.dispose();
    });
  });

  // SHARECTL-app: the host can revoke a speaker's VIDEO sources (camera +
  // screen-share) while leaving their microphone alone (see
  // docs/superpowers/specs/2026-07-18-spaces-host-share-control-design.md in
  // the skchat server repo). The wire signal is
  // `ParticipantPermissions.canPublishSources`, a
  // `List<lk_models.TrackSource>` of the INSTALLED livekit_client
  // 2.5.0+hotfix.3 proto enum (lib/src/proto/livekit_models.pbenum.dart:
  // TrackSource.{UNKNOWN,CAMERA,MICROPHONE,SCREEN_SHARE,SCREEN_SHARE_AUDIO}),
  // NOT the client-facing `TrackSource` enum the rest of this file uses for
  // `getTrackPublicationBySource` (types/other.dart: camera, microphone,
  // screenShareVideo, screenShareAudio). The livekit_client barrel exports
  // only the latter under the bare name `TrackSource` (src/extensions.dart's
  // `toLKType()` bridge between the two is deliberately NOT re-exported,
  // barrel `show`s only `WidgetsBindingCompatible` from that file), so
  // canPublishVideoFromSourceNames reads the proto enum's `.name` (a
  // `ProtobufEnum` member, always public) rather than importing the internal
  // proto library by path. Kept on plain `List<String>` so it stays
  // independently unit-testable without constructing real proto instances.
  group('LiveKitParticipantSnapshot.canPublishVideoFromSourceNames', () {
    test('empty list means no source restriction encoded: defaults true '
        '(default policy unchanged - any speaker can share until the host '
        'explicitly narrows the grant)', () {
      expect(
        LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(const []),
        isTrue,
      );
    });

    test('full sources (mic + camera + screen share + screen share audio) '
        'is true', () {
      expect(
        LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(const [
          'MICROPHONE',
          'CAMERA',
          'SCREEN_SHARE',
          'SCREEN_SHARE_AUDIO',
        ]),
        isTrue,
      );
    });

    test('mic-only (host disabled sharing) is false', () {
      expect(
        LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(
            const ['MICROPHONE']),
        isFalse,
      );
    });

    test('camera alone (no screen share) is still true', () {
      expect(
        LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(
            const ['MICROPHONE', 'CAMERA']),
        isTrue,
      );
    });

    test('screen share alone (no camera) is still true', () {
      expect(
        LiveKitParticipantSnapshot.canPublishVideoFromSourceNames(
            const ['MICROPHONE', 'SCREEN_SHARE']),
        isTrue,
      );
    });
  });

  group('LiveKitParticipantSnapshot.canPublishVideo default', () {
    test('defaults to true when not supplied (matches the unchanged-default '
        'sharing policy)', () {
      const snap = LiveKitParticipantSnapshot(
        identity: 'chef',
        isLocal: true,
        isMuted: false,
        isCameraEnabled: false,
      );
      expect(snap.canPublishVideo, isTrue);
    });
  });
}
