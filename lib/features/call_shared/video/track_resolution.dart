/// One room graph, one set of answers to "what video should this surface
/// draw".
///
/// These resolvers used to live in `features/spaces/screen_share_helper.dart`
/// alongside the native-desktop capture-source picker, which put two unrelated
/// jobs in one file and, worse, put the CALLS feature's tile resolver inside
/// the SPACES feature: `livekit_call_screen.dart` imported
/// `../spaces/screen_share_helper.dart` just to reach
/// [resolveTileVideoTrack]. A sibling feature reaching sideways into another
/// feature is the wrong direction of dependency, and it only got wronger once
/// the shared grid started consuming the same lookups.
///
/// They moved here WHOLESALE rather than being split down the middle, and that
/// is deliberate. [_renderableTrack] is the single rule for "is there a
/// renderable video on this publication", and the whole reason it exists is
/// that the calls resolver and the Spaces resolvers once disagreed about
/// `muted` (see its own comment). Moving only the calls half would have left
/// two copies of that rule in two files, recreating exactly the divergence it
/// was written to end. So every resolver that walks the room graph lives here,
/// and `screen_share_helper.dart` keeps only the capture-source picker its
/// name actually describes (plus a re-export of this file, so no Spaces call
/// site or test had to move in the same change).
library;

import "package:livekit_client/livekit_client.dart";

import "../../../services/livekit_call_service.dart";

/// One live screen-share: the sharer's [identity], the live [VideoTrack], and
/// whether the share is the local participant's own screen.
typedef ScreenShare = ({String identity, VideoTrack track, bool isLocal});

/// One live video source feeding the Space watch stage: a screen share OR a
/// camera go-live. Mirrors [ScreenShare]'s shape ([identity], [track],
/// [isLocal]) plus [isCamera] so the stage can pick the right label/icon
/// (camera go-live vs screen share) while sharing one render path (the same
/// [VideoTrackRenderer] tile either way).
typedef StageVideo = ({
  String identity,
  VideoTrack track,
  bool isLocal,
  bool isCamera,
});

/// The one rule for "is there a renderable video track on this publication".
/// A missing publication (never published, unsubscribed, or torn down) and a
/// MUTED publication both mean no video: the SFU stops forwarding a muted
/// track, so drawing it would pin the last decoded frame on screen instead of
/// falling back to nothing (or, for a caller trying more than one source in
/// priority order, to the next source).
///
/// Every resolver in this file funnels through here, and that consolidation
/// is the point. Before this helper existed, [_resolveTracksBySource]
/// (backing the whole Spaces stage: [resolveScreenShares],
/// [resolveCameraShares], [resolveStageVideos]) never checked `muted` at all,
/// while [resolveTileVideoTrack] (the calls surface) did. The same
/// participant at the same instant could then show "no video" on a call tile
/// and "video" on the Spaces stage, purely by which resolver asked. A shared
/// layout engine now consumes both paths, and that divergence would have
/// looked like a layout bug (why does this tile render differently on two
/// surfaces) rather than what it actually was: two resolvers disagreeing
/// about one room graph.
VideoTrack? _renderableTrack(TrackPublication? pub) {
  if (pub == null || pub.muted) return null;
  final track = pub.track;
  return track is VideoTrack ? track : null;
}

/// Resolve every live [VideoTrack] published on [source] in the [room],
/// keyed to the [participants] snapshot list. Shared lookup behind
/// [resolveScreenShares] (TrackSource.screenShareVideo) and
/// [resolveCameraShares] (TrackSource.camera): only the [TrackSource]
/// differs, so the identity-keyed room-graph walk lives here once.
///
/// The [LiveKitParticipantSnapshot] does not carry the underlying track, so we
/// look it up in the live room by identity via
/// `getTrackPublicationBySource(source)` (the same approach the call grid
/// uses for camera tracks). Unlike an older remote-only lookup this ALSO
/// returns the LOCAL participant's own publication, so the watch stage can
/// show the host what they are streaming. Callers that only want remote
/// video can filter on `!s.isLocal`.
List<ScreenShare> _resolveTracksBySource(
  Room? room,
  List<LiveKitParticipantSnapshot> participants,
  TrackSource source,
) {
  if (room == null) return const [];
  final out = <ScreenShare>[];
  for (final p in participants) {
    if (p.isLocal) {
      final local = room.localParticipant;
      if (local == null) continue;
      final track = _renderableTrack(local.getTrackPublicationBySource(source));
      if (track != null) {
        out.add((identity: p.identity, track: track, isLocal: true));
      }
      continue;
    }
    final remote = room.remoteParticipants[p.identity];
    if (remote == null) continue;
    final track = _renderableTrack(remote.getTrackPublicationBySource(source));
    if (track != null) {
      out.add((identity: p.identity, track: track, isLocal: false));
    }
  }
  return out;
}

/// Resolve every live screen-share [VideoTrack] in the [room], keyed to the
/// [participants] snapshot list. See [_resolveTracksBySource] for the shared
/// lookup. Used by [ScreenSharePanel], which is deliberately screen-share
/// only; unchanged by the Spaces camera go-live feature.
List<ScreenShare> resolveScreenShares(
  Room? room,
  List<LiveKitParticipantSnapshot> participants,
) =>
    _resolveTracksBySource(room, participants, TrackSource.screenShareVideo);

/// Resolve every live CAMERA [VideoTrack] in the [room] (a Spaces "Go live"
/// camera publish, `TrackSource.camera`), keyed to the [participants]
/// snapshot list. Same identity-keyed lookup as [resolveScreenShares], just a
/// different [TrackSource].
List<ScreenShare> resolveCameraShares(
  Room? room,
  List<LiveKitParticipantSnapshot> participants,
) =>
    _resolveTracksBySource(room, participants, TrackSource.camera);

/// Look up the live [TrackPublication] carrying [source] for [participant] in
/// the [room]. Same identity-keyed room-graph walk as
/// [_resolveTracksBySource], for the single-participant case a call tile
/// needs. Returns null for a missing room, a participant who has left, or a
/// participant with nothing published on that source.
TrackPublication? _publicationFor(
  Room? room,
  LiveKitParticipantSnapshot participant,
  TrackSource source,
) {
  if (room == null) return null;
  if (participant.isLocal) {
    return room.localParticipant?.getTrackPublicationBySource(source);
  }
  return room.remoteParticipants[participant.identity]
      ?.getTrackPublicationBySource(source);
}

/// Resolve the one [VideoTrack] a CALL tile should draw for [participant], or
/// null when there is no live video to show (the tile then keeps its existing
/// avatar / audio-only presentation).
///
/// Screen share wins over camera, which is both [resolveStageVideos]' ordering
/// and the call grid's own long-standing preference: someone sharing content
/// wants the content seen.
///
/// Every input is read from the LIVE room, never from the participant
/// snapshot, and that is the point. [LiveKitParticipantSnapshot] is a value
/// captured when the service last emitted; a tile rebuilt from it later used
/// to let the snapshot's `isCameraEnabled` copy veto a track that was already
/// subscribed and decoding, so nothing was drawn even though frames were
/// arriving. A remote publisher that never touches a local camera toggle (the
/// Lumina call agent publishes her portrait server-side, after her audio
/// track) is exactly the case that veto gets wrong. The Spaces resolvers above
/// have never consulted that field, so this brings the call grid onto the same
/// rule.
///
/// "Is there a video to draw" (including the muted-publication rule) is
/// [_renderableTrack]'s job, not this function's: every source below is
/// checked the same way [_resolveTracksBySource] checks its sources, so a
/// participant cannot get a different answer here than on the Spaces stage.
/// This function's own job is just the screen-over-camera priority order.
VideoTrack? resolveTileVideoTrack(
  Room? room,
  LiveKitParticipantSnapshot participant,
) {
  for (final source in const [
    TrackSource.screenShareVideo,
    TrackSource.camera,
  ]) {
    final track = _renderableTrack(_publicationFor(room, participant, source));
    if (track != null) return track;
  }
  return null;
}

/// Resolve every live video source feeding the Space watch stage: screen
/// shares first (kept in their existing priority position when both exist),
/// then camera go-lives. Used by `_Stage` (space_room_screen.dart) INSTEAD
/// of [resolveScreenShares] alone so the stage (and therefore fullscreen)
/// renders a camera go-live too, not only a screen share. [resolveScreenShares]
/// itself stays unchanged for [ScreenSharePanel]'s screen-only lane.
List<StageVideo> resolveStageVideos(
  Room? room,
  List<LiveKitParticipantSnapshot> participants,
) {
  final screens = resolveScreenShares(room, participants);
  final cameras = resolveCameraShares(room, participants);
  return [
    for (final s in screens)
      (
        identity: s.identity,
        track: s.track,
        isLocal: s.isLocal,
        isCamera: false,
      ),
    for (final c in cameras)
      (
        identity: c.identity,
        track: c.track,
        isLocal: c.isLocal,
        isCamera: true,
      ),
  ];
}
