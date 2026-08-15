/// Room-scoped Space chat: owns the "chat" lane subscription and the message
/// list for the life of the Space, not for the life of a bottom sheet.
///
/// This is the same fix `WatchSession` already got, for the same reason and
/// with the same shape. `SpaceChatPanel` built its OWN [LaneService] in
/// `initState` and kept messages in local widget state, so closing the panel
/// destroyed the subscription along with them. Two consequences, both of which
/// this replaces:
///
///  * Every message that arrived while the panel was closed was DROPPED. The
///    inbound listener was guarded by `if (!mounted) return`, so the app never
///    saw it. Chat only appeared to work because reopening the panel re-fetched
///    the whole history from the server store. There was therefore nothing to
///    count and nothing to badge: "unread" did not exist as a concept, and no
///    amount of UI could have shown it.
///  * The panel's `dispose` cancelled its text and scroll controllers but never
///    the lane subscription, so every open leaked a [LaneService] and a stream
///    listener for the life of the Space.
library;

import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../services/lane_service.dart";
import "../calls/cast_sheet.dart" show activeCastSessionProvider;
import "watch_session.dart"
    show WatchSessionArgs, laneServiceFactoryProvider;


// ── Family key ───────────────────────────────────────────────────────────────

/// Family key for [spaceChatProvider]. Needs value equality for exactly the
/// reason [WatchSessionArgs] does: the panel and the control bar's unread badge
/// each build their own instance for the same room, and Riverpod family lookup
/// keys on `==` / `hashCode`. Without it they would resolve to two different
/// notifiers, each with its own lane subscription and its own idea of how many
/// messages are unread.
class SpaceChatArgs {
  const SpaceChatArgs({required this.spaceId, required this.identity});

  final String spaceId;
  final String identity;

  @override
  bool operator ==(Object other) =>
      other is SpaceChatArgs &&
      other.spaceId == spaceId &&
      other.identity == identity;

  @override
  int get hashCode => Object.hash(spaceId, identity);
}

// ── State ────────────────────────────────────────────────────────────────────

class SpaceChatState {
  const SpaceChatState({
    this.messages = const [],
    this.unread = 0,
    this.isOpen = false,
  });

  /// Every message this client knows about, oldest first: the catch-up replay
  /// followed by everything that has arrived live since.
  final List<Map<String, dynamic>> messages;

  /// Messages that have arrived since the panel was last open. Drives the
  /// Tools badge. Never counts our own sends, and never grows while the panel
  /// is open, because both would be counting something the user is already
  /// looking at.
  final int unread;

  /// Whether the chat panel is currently on screen.
  final bool isOpen;

  /// The most recent message, or null when the room has said nothing yet.
  Map<String, dynamic>? get latest =>
      messages.isEmpty ? null : messages.last;

  SpaceChatState copyWith({
    List<Map<String, dynamic>>? messages,
    int? unread,
    bool? isOpen,
  }) =>
      SpaceChatState(
        messages: messages ?? this.messages,
        unread: unread ?? this.unread,
        isOpen: isOpen ?? this.isOpen,
      );
}

// ── Notifier ─────────────────────────────────────────────────────────────────

class SpaceChatSession
    extends AutoDisposeFamilyNotifier<SpaceChatState, SpaceChatArgs> {
  late final LaneLike _lane;

  /// Set only inside [ref.onDispose]. Guards the [_lane.catchUp] continuation,
  /// which is an HTTP round trip a user backing out of the Space mid-join
  /// races against. Mirrors the identical guard in `WatchSession`.
  bool _disposed = false;

  @override
  SpaceChatState build(SpaceChatArgs arg) {
    // Reuses the watch lane's factory seam deliberately. Despite the name it
    // is lane-generic (it only ever reads `args.spaceId` to build the
    // LaneService), overriding it is how every existing Spaces widget test
    // already substitutes a fake lane, and reusing it means this file adds a
    // second lane consumer without editing watch_session.dart at all.
    _lane = ref.read(laneServiceFactoryProvider)(
      WatchSessionArgs(spaceId: arg.spaceId, identity: arg.identity),
    );

    // Replay history for a late joiner. Deliberately does NOT mark anything
    // unread: arriving to a room with 200 messages of backlog and a "200"
    // badge is noise, not information. Unread means "since you were last
    // looking", and a joiner has never been looking.
    _lane.catchUp("chat").then((events) {
      if (_disposed) return;
      state = state.copyWith(messages: [...state.messages, ...events]);
    });

    final sub =
        _lane.inbound.where((j) => j["lane"] == "chat").listen(_applyRemote);

    // autoDispose is load-bearing, same as WatchSession: a keepAlive family
    // member never runs this, so leaving the Space would leak the subscription
    // and keep this session listening to a room the user already left.
    ref.onDispose(() {
      _disposed = true;
      sub.cancel();
    });

    return const SpaceChatState();
  }

  /// A message from the lane.
  ///
  /// LiveKit never loops a live data-channel send back to its own sender, so
  /// anything arriving here is from someone else. The `from` check is belt and
  /// braces for a transport that ever changes that, since counting our own
  /// message as unread would be a badge the user can never explain.
  void _applyRemote(Map<String, dynamic> e) {
    if (_disposed) return;
    final mine = e["from"] == arg.identity;
    state = state.copyWith(
      messages: [...state.messages, e],
      unread: (state.isOpen || mine) ? state.unread : state.unread + 1,
    );
  }

  /// Record a locally-sent message and publish it.
  ///
  /// The optimistic append is what makes the sender's own message appear
  /// instantly instead of after the server round trip, and it is why [send]
  /// lives here rather than in the panel: the panel is disposable, this is not.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final msg = <String, dynamic>{
      "lane": "chat",
      "from": arg.identity,
      "text": trimmed,
      "ts": DateTime.now().millisecondsSinceEpoch,
    };
    state = state.copyWith(messages: [...state.messages, msg]);
    await _lane.publish(msg);
  }

  /// The panel opened: the user is looking, so nothing is unread any more.
  void markOpen() => state = state.copyWith(isOpen: true, unread: 0);

  /// The panel closed. Messages from here on count again.
  void markClosed() => state = state.copyWith(isOpen: false);
}

final spaceChatProvider = AutoDisposeNotifierProviderFamily<SpaceChatSession,
    SpaceChatState, SpaceChatArgs>(SpaceChatSession.new);

// ── Preview redaction policy ─────────────────────────────────────────────────

/// Whether a chat notification may show the message TEXT, or only who sent it.
///
/// Chef: "if you are broadcasting on a tv, you may not want the group messages
/// being displayed to everyone", then: "can you detect if you are airplaying
/// or casting? if you are, then it only shows sender; if you are NOT airplay
/// or casting, they show the messages."
///
/// Detected rather than configured, on purpose. A "presentation mode" toggle
/// is a mode you have to remember to set BEFORE the room is looking at your
/// screen, and the failure is unrecoverable: the text is already on the TV.
///
/// Two signals, both of which mean this device's screen is in front of people
/// who are not its owner:
///
///  * [casting] - an HLS cast session is running (see activeCastSessionProvider),
///    which is the "Cast to TV" flow including its Chromecast and AirPlay
///    routes.
///  * [screenSharing] - the local participant is publishing a screen share, so
///    the whole room is already watching this screen. Worth folding in here
///    because it is the ordinary watch-party setup: the host shares the video,
///    and a chat toast on that screen is as public as anything on the TV.
///
/// KNOWN GAP, and it is not small: system-level screen mirroring started from
/// the iOS Control Center is invisible to the app. There is no web API for it
/// at all, and on native it would take a platform channel reading
/// UIScreen.screens. Someone who AirPlays that way gets message text on the TV.
/// A user-facing toggle is the honest cover for that case, and is deliberately
/// left for a follow-up rather than half-built here.
bool mayShowMessageText({
  required bool casting,
  required bool screenSharing,
}) =>
    !casting && !screenSharing;

/// [mayShowMessageText] wired to the app's live cast state. The screen-share
/// half is passed in by the caller, which is the only place that holds the
/// local participant snapshot.
final chatPreviewMayShowTextProvider =
    Provider.family<bool, bool>((ref, screenSharing) {
  final casting = ref.watch(activeCastSessionProvider) != null;
  return mayShowMessageText(casting: casting, screenSharing: screenSharing);
});
