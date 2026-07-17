import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_webrtc/flutter_webrtc.dart" show DesktopCapturerSource;
import "package:livekit_client/livekit_client.dart";

import "../../services/livekit_call_service.dart";

/// True on native desktop (Linux / macOS / Windows), where flutter_webrtc
/// requires an explicit capture `sourceId` from `desktopCapturer.getSources()`
/// before `getDisplayMedia` can resolve a source. Always false on web (the
/// browser owns its own picker) and on mobile.
bool get isDesktopScreenShare => !kIsWeb && lkPlatformIsDesktop();

/// Resolve the capture source id to pass into
/// [LiveKitCallService.setScreenShareEnabled] before starting a share.
///
/// On web this is a no-op: returns `(proceed: true, sourceId: null)`
/// immediately, since the browser supplies its own `getDisplayMedia` picker.
///
/// On native desktop it shows the SDK's bundled [ScreenSelectDialog] and
/// returns `(proceed: true, sourceId: <picked id>)` for a chosen source, or
/// `(proceed: false, sourceId: null)` if the user cancelled the dialog. A
/// cancelled pick means the caller MUST NOT start the share (no error, just
/// a silent no-op).
Future<({bool proceed, String? sourceId})> resolveScreenShareSource(
  BuildContext context,
) async {
  if (!isDesktopScreenShare) {
    return (proceed: true, sourceId: null);
  }
  final source = await showDialog<DesktopCapturerSource>(
    context: context,
    builder: (_) => ScreenSelectDialog(),
  );
  if (source == null) {
    return (proceed: false, sourceId: null);
  }
  return (proceed: true, sourceId: source.id);
}

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
