import "package:flutter/foundation.dart"
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_webrtc/flutter_webrtc.dart"
    show DesktopCapturerSource, SourceType, ThumbnailSize, desktopCapturer;
import "package:livekit_client/livekit_client.dart";

import "../../core/theme/sovereign_colors.dart";
import "../../services/livekit_call_service.dart";

/// True on native desktop (Linux / macOS / Windows), where flutter_webrtc
/// requires an explicit capture `sourceId` from `desktopCapturer.getSources()`
/// before `getDisplayMedia` can resolve a source. Always false on web (the
/// browser owns its own picker) and on mobile.
bool get isDesktopScreenShare => !kIsWeb && lkPlatformIsDesktop();

/// Testable seam behind [isMobileWeb]. Mobile browsers (iOS Safari, Android
/// Chrome) have no `getDisplayMedia`, so screen-share origination is not
/// just unsupported by our app, it is impossible on that platform.
/// livekit_client's own `lkPlatformIsWebMobile()` guard (video.dart) throws
/// a raw, unfriendly exception the moment a share is attempted there; the
/// Go live affordance must detect this case first and never reach that
/// guard.
///
/// `kIsWeb` is a compile-time constant (always `false` on the `flutter
/// test` VM, since tests never run inside a browser) and
/// `defaultTargetPlatform` reflects the host OS running the test, not an
/// arbitrary platform under test. Neither is fakeable in a plain unit test,
/// so this function accepts both as optional overrides and falls back to
/// the real values when omitted, which is what [isMobileWeb] does.
bool isMobileWebPlatform({bool? isWeb, TargetPlatform? platform}) {
  final web = isWeb ?? kIsWeb;
  final target = platform ?? defaultTargetPlatform;
  return web &&
      (target == TargetPlatform.iOS || target == TargetPlatform.android);
}

/// True ONLY for Flutter web running inside a phone browser (iOS Safari,
/// Android Chrome). Always false on desktop web and on every native target,
/// including native mobile: native mobile screen share is a separate,
/// not-yet-built feature (contrast [isDesktopScreenShare] above, which
/// covers the native-desktop case).
///
/// Go live / screen-share entry points (Spaces control bar, conference
/// control bar, 1:1 call control bar) check this before attempting a share
/// so a mobile-web user sees a friendly message instead of the raw LiveKit
/// exception.
bool get isMobileWeb => isMobileWebPlatform();

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
      backgroundColor: SovereignColors.surfaceCard,
      title: const Text(
        "Choose what to share",
        style: TextStyle(color: SovereignColors.textPrimary),
      ),
      children: [
        for (final s in screens)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(
              s.name.isNotEmpty ? s.name : "Screen",
              style: const TextStyle(color: SovereignColors.textPrimary),
            ),
          ),
        for (final s in windows)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(s),
            child: Text(
              s.name.isNotEmpty ? s.name : "Window",
              style: const TextStyle(color: SovereignColors.textPrimary),
            ),
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
      final pub = local.getTrackPublicationBySource(source);
      final track = pub?.track;
      if (track is VideoTrack) {
        out.add((identity: p.identity, track: track as VideoTrack, isLocal: true));
      }
      continue;
    }
    final remote = room.remoteParticipants[p.identity];
    if (remote == null) continue;
    final pub = remote.getTrackPublicationBySource(source);
    final track = pub?.track;
    if (track is VideoTrack) {
      out.add((identity: p.identity, track: track as VideoTrack, isLocal: false));
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
/// A publication whose `muted` flag is set is deliberately still treated as
/// "no video": the SFU stops forwarding a muted track, so drawing it would
/// pin the last decoded frame on screen instead of falling back. The flag is
/// read off the live publication here rather than off the snapshot, so it can
/// never be stale relative to what is being drawn.
VideoTrack? resolveTileVideoTrack(
  Room? room,
  LiveKitParticipantSnapshot participant,
) {
  for (final source in const [
    TrackSource.screenShareVideo,
    TrackSource.camera,
  ]) {
    final pub = _publicationFor(room, participant, source);
    if (pub == null || pub.muted) continue;
    final track = pub.track;
    // An unsubscribed or torn-down publication has a null track, which is how
    // a track going away mid-call falls back cleanly instead of freezing.
    if (track is VideoTrack) return track;
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
