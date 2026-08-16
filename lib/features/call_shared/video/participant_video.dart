import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:livekit_client/livekit_client.dart";

import "../../../services/livekit_call_service.dart";
import "track_resolution.dart";

/// Builds the widget that actually draws [track].
///
/// A seam, not a feature: `VideoTrackRenderer` needs the flutter_webrtc
/// platform channel, which does not exist under `flutter test`, so the
/// late-arrival / track-removal behaviour of [ParticipantVideo] could not
/// otherwise be tested at all. Production never overrides this; the default IS
/// the real renderer.
typedef CallVideoRendererBuilder = Widget Function(VideoTrack track);

Widget _defaultCallVideoRenderer(VideoTrack track) => VideoTrackRenderer(
      track,
      // The call agent's portrait is 560x720. `contain` letterboxes it inside
      // the tile instead of stretching it to the tile's aspect ratio.
      fit: VideoViewFit.contain,
    );

/// DI seam around [_defaultCallVideoRenderer], mirroring
/// `screenShareSourceResolverProvider`'s pattern.
///
/// This provider moved here with the widget it feeds, and the identifier is
/// deliberately unchanged: it is the ONLY reason any of the call video widgets
/// can be mounted headless, so every widget test that draws a tile overrides
/// it by name.
final callVideoRendererBuilderProvider = Provider<CallVideoRendererBuilder>(
  (ref) => _defaultCallVideoRenderer,
);

/// The video (or avatar-fallback) layer of one participant tile.
///
/// Stateful, and subscribed to the live room's own track events, because the
/// video is NOT guaranteed to exist when the tile is first built. In a 1:1
/// call with the Lumina agent the audio track is published first and the
/// portrait video only afterwards, so the screen is already up and audio-only
/// by the time the video appears. Anything that resolves the track once at
/// build time and never listens shows an avatar forever against a server that
/// is publishing correctly, which is exactly the failure this widget exists to
/// remove.
///
/// The room event bus is the authority here rather than the participant
/// snapshot stream: the snapshot is a value object that carries no track, so
/// a tile driven only by snapshots depends on a second subsystem re-emitting
/// at the right moment to discover video that is already subscribed.
/// Subscribing to (un)publish / (un)subscribe / (un)mute directly makes this
/// tile correct on its own.
///
/// That self-sufficiency is why this widget is the piece worth sharing rather
/// than reimplementing per surface: a surface that resolves tracks off a
/// snapshot stream only repaints when the snapshot happens to tick, which
/// looks like "video sometimes does not appear" and is very hard to reproduce.
class ParticipantVideo extends ConsumerStatefulWidget {
  const ParticipantVideo({
    super.key,
    required this.room,
    required this.snapshot,
    required this.fallback,
  });

  final Room? room;
  final LiveKitParticipantSnapshot snapshot;

  /// Shown whenever there is no live video: the existing audio-only avatar
  /// presentation, unchanged.
  final Widget fallback;

  @override
  ConsumerState<ParticipantVideo> createState() => _ParticipantVideoState();
}

class _ParticipantVideoState extends ConsumerState<ParticipantVideo> {
  EventsListener<RoomEvent>? _events;

  @override
  void initState() {
    super.initState();
    _bind(widget.room);
  }

  @override
  void didUpdateWidget(covariant ParticipantVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reconnect swaps the Room instance; re-point the listener or this tile
    // would keep listening to a dead bus and never repaint again.
    if (!identical(oldWidget.room, widget.room)) {
      _events?.dispose();
      _events = null;
      _bind(widget.room);
    }
  }

  @override
  void dispose() {
    _events?.dispose();
    _events = null;
    super.dispose();
  }

  void _bind(Room? room) {
    if (room == null) return;
    _events = room.createListener()
      // Published / unpublished covers the remote starting or stopping a
      // source; subscribed / unsubscribed covers the track itself arriving or
      // being torn down (a torn-down publication reports a null track, so the
      // repaint falls back to the avatar rather than freezing on the last
      // decoded frame).
      ..on<TrackPublishedEvent>((_) => _repaint())
      ..on<TrackUnpublishedEvent>((_) => _repaint())
      ..on<TrackSubscribedEvent>((_) => _repaint())
      ..on<TrackUnsubscribedEvent>((_) => _repaint())
      ..on<LocalTrackPublishedEvent>((_) => _repaint())
      ..on<LocalTrackUnpublishedEvent>((_) => _repaint())
      // A muted video track stops being forwarded by the SFU, so it has to
      // fall back too, and unmute has to bring it straight back.
      ..on<TrackMutedEvent>((_) => _repaint())
      ..on<TrackUnmutedEvent>((_) => _repaint());
  }

  /// Re-resolve on the next build. The events fire for every participant in
  /// the room, so this deliberately does no filtering: resolving is a cheap
  /// map lookup, and filtering on identity here would be one more place to get
  /// the agent's `#agent`-suffixed identity wrong.
  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final track = resolveTileVideoTrack(widget.room, widget.snapshot);
    if (track == null) return widget.fallback;
    return Positioned.fill(
      child: ref.watch(callVideoRendererBuilderProvider)(track),
    );
  }
}
