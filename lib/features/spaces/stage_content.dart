import "screen_share_helper.dart";

/// What the Space's main stage is currently showing.
enum StageKind {
  /// No live video and no active watch session: the plain audio-room layout
  /// (speaker rings / listener dots), no video area at all.
  none,

  /// At least one live screen share or camera go-live. This outranks a watch
  /// session on purpose: going live is a deliberate, interruptive act, and
  /// the watch video keeps playing and staying synced underneath, so a host
  /// can cut in over a movie without ending it for everyone in the room.
  liveVideo,

  /// A Watch Together session is active and nobody is live, so the shared
  /// video owns the stage.
  watch,
}

/// Resolve which content the Space's main stage should show, given the
/// LiveKit-only [videos] (screen shares / camera go-lives, see
/// [resolveStageVideos]) and whether a Watch Together session is active.
///
/// Deliberately composed at the call site instead of folded into
/// [resolveStageVideos]: that function is a pure LiveKit-only seam
/// ([resolveStageVideos]'s own doc explains why `ScreenSharePanel` still
/// needs a screen-only lane), and mixing the watch session into it would
/// give a room-graph query a second, unrelated reason to change.
StageKind resolveStageKind({
  required List<StageVideo> videos,
  required bool watchActive,
}) {
  if (videos.isNotEmpty) return StageKind.liveVideo;
  if (watchActive) return StageKind.watch;
  return StageKind.none;
}
