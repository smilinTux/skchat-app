import "package:livekit_client/livekit_client.dart";

import "../../services/livekit_call_service.dart";

/// One live screen-share: the sharer's [identity], the live [VideoTrack], and
/// whether the share is the local participant's own screen.
typedef ScreenShare = ({String identity, VideoTrack track, bool isLocal});

/// Resolve every live screen-share [VideoTrack] in the [room], keyed to the
/// [participants] snapshot list.
///
/// The [LiveKitParticipantSnapshot] does not carry the underlying track, so we
/// look it up in the live room by identity via
/// `getTrackPublicationBySource(TrackSource.screenShareVideo)` (the same
/// approach the call grid uses for camera tracks). Unlike the older
/// remote-only lookup this ALSO returns the LOCAL participant's own share, so
/// the watch stage can show the host what they are streaming. Callers that
/// only want remote shares can filter on `!s.isLocal`.
List<ScreenShare> resolveScreenShares(
  Room? room,
  List<LiveKitParticipantSnapshot> participants,
) {
  if (room == null) return const [];
  final out = <ScreenShare>[];
  for (final p in participants) {
    if (p.isLocal) {
      final local = room.localParticipant;
      if (local == null) continue;
      final pub =
          local.getTrackPublicationBySource(TrackSource.screenShareVideo);
      final track = pub?.track;
      if (track is VideoTrack) {
        out.add((identity: p.identity, track: track as VideoTrack, isLocal: true));
      }
      continue;
    }
    final remote = room.remoteParticipants[p.identity];
    if (remote == null) continue;
    final pub =
        remote.getTrackPublicationBySource(TrackSource.screenShareVideo);
    final track = pub?.track;
    if (track is VideoTrack) {
      out.add((identity: p.identity, track: track as VideoTrack, isLocal: false));
    }
  }
  return out;
}
