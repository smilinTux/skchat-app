import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_webrtc/flutter_webrtc.dart"
    show DesktopCapturerSource, SourceType, ThumbnailSize, desktopCapturer;
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
/// On native desktop it enumerates sources ONCE via
/// `desktopCapturer.getSources()` with a negligible 1x1 thumbnail size (no
/// live thumbnail refresh) and shows a lightweight text-list picker. It
/// returns `(proceed: true, sourceId: <picked id>)` for a chosen source, or
/// `(proceed: false, sourceId: null)` if the user cancelled the dialog or no
/// sources were found. A cancelled pick means the caller MUST NOT start the
/// share (no error, just a silent no-op).
///
/// This intentionally avoids flutter_webrtc's bundled `ScreenSelectDialog`,
/// which runs a `Timer.periodic` re-grabbing live thumbnails of every window
/// and screen every few seconds. On Linux/X11 with an integrated GPU that
/// repeated compositor grab can be heavy enough to crash the whole desktop
/// session, so this picker enumerates sources exactly once and never
/// refreshes thumbnails.
Future<({bool proceed, String? sourceId})> resolveScreenShareSource(
  BuildContext context,
) async {
  if (!isDesktopScreenShare) {
    return (proceed: true, sourceId: null);
  }
  final sources = await desktopCapturer.getSources(
    types: [SourceType.Screen, SourceType.Window],
    thumbnailSize: ThumbnailSize(1, 1),
  );
  if (sources.isEmpty) {
    return (proceed: false, sourceId: null);
  }
  final screens = sources.where((s) => s.type == SourceType.Screen).toList();
  final windows = sources.where((s) => s.type == SourceType.Window).toList();
  if (!context.mounted) {
    return (proceed: false, sourceId: null);
  }
  final source = await showDialog<DesktopCapturerSource>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text("Choose what to share"),
      children: [
        for (final s in screens)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(s.name.isNotEmpty ? s.name : "Screen"),
          ),
        for (final s in windows)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(s.name.isNotEmpty ? s.name : "Window"),
          ),
      ],
    ),
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
