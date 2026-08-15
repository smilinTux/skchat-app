import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/calls/cast_sheet.dart"
    show activeCastSessionProvider;
import "package:skchat/features/spaces/space_chat_session.dart";
import "package:skchat/features/spaces/watch_session.dart"
    show laneServiceFactoryProvider;
import "package:skchat/services/cast_service.dart" show HlsCastSession;
import "package:skchat/services/lane_service.dart";

/// Records publishes and lets a test push inbound / catch-up events without a
/// network or a real LiveKit room.
class FakeLane implements LaneLike {
  final _inboundCtl = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> persisted = [];
  final List<Map<String, dynamic>> ephemeral = [];
  List<Map<String, dynamic>> catchUpEvents = const [];

  @override
  Stream<Map<String, dynamic>> get inbound => _inboundCtl.stream;

  @override
  Future<void> publish(Map<String, dynamic> payload) async =>
      persisted.add(payload);

  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async =>
      ephemeral.add(payload);

  Completer<List<Map<String, dynamic>>>? _pendingCatchUp;

  @override
  Future<List<Map<String, dynamic>>> catchUp(String lane) {
    final pending = _pendingCatchUp;
    if (pending != null) return pending.future;
    return Future.value(catchUpEvents);
  }

  Completer<List<Map<String, dynamic>>> holdCatchUp() {
    final c = Completer<List<Map<String, dynamic>>>();
    _pendingCatchUp = c;
    return c;
  }

  void pushInbound(Map<String, dynamic> e) => _inboundCtl.add(e);

  bool get hasListener => _inboundCtl.hasListener;

  void close() => _inboundCtl.close();
}

const _args = SpaceChatArgs(spaceId: "s1", identity: "me");

Map<String, dynamic> _msg(String from, String text) =>
    {"lane": "chat", "from": from, "text": text};

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeLane lane;
  late ProviderContainer container;

  setUp(() {
    lane = FakeLane();
    container = ProviderContainer(overrides: [
      laneServiceFactoryProvider.overrideWithValue((_) => lane),
    ]);
    addTearDown(container.dispose);
    addTearDown(lane.close);
  });

  SpaceChatSession notifier() {
    final sub = container.listen(spaceChatProvider(_args), (_, _) {});
    addTearDown(sub.close);
    return container.read(spaceChatProvider(_args).notifier);
  }

  SpaceChatState state() => container.read(spaceChatProvider(_args));

  group("messages arriving while the panel is closed", () {
    test("are KEPT and counted, which is the whole bug", () async {
      // SpaceChatPanel built its own lane in initState and guarded the inbound
      // listener with `if (!mounted) return`, so a message that arrived while
      // the sheet was closed was dropped outright. Nothing could be badged
      // because nothing was counted, and reopening only looked correct because
      // catchUp re-fetched history from the server.
      final n = notifier();
      await _flush();

      lane.pushInbound(_msg("casey", "starting in 5"));
      lane.pushInbound(_msg("casey", "you there?"));
      await _flush();

      expect(state().unread, 2);
      expect(state().messages.length, 2);
      expect(n.state.latest?["text"], "you there?");
    });

    test("opening the panel clears the count", () async {
      final n = notifier();
      await _flush();
      lane.pushInbound(_msg("casey", "hi"));
      await _flush();
      expect(state().unread, 1);

      n.markOpen();

      expect(state().unread, 0);
      expect(state().isOpen, isTrue);
      // The message itself is not thrown away, only its unread status.
      expect(state().messages.length, 1);
    });

    test("nothing accrues while the panel is open", () async {
      final n = notifier();
      await _flush();
      n.markOpen();

      lane.pushInbound(_msg("casey", "watching this"));
      await _flush();

      expect(state().unread, 0,
          reason: "badging a message the user is looking at is noise");
      expect(state().messages.length, 1);
    });

    test("counting resumes once it closes again", () async {
      final n = notifier();
      await _flush();
      n.markOpen();
      lane.pushInbound(_msg("casey", "seen"));
      await _flush();

      n.markClosed();
      lane.pushInbound(_msg("casey", "unseen"));
      await _flush();

      expect(state().unread, 1);
      expect(state().messages.length, 2);
    });
  });

  group("our own messages", () {
    test("never count as unread", () async {
      // A badge the user cannot explain is worse than no badge.
      notifier();
      await _flush();

      lane.pushInbound(_msg("me", "echo of my own send"));
      await _flush();

      expect(state().unread, 0);
    });

    test("send appends optimistically and publishes on the persisted path",
        () async {
      final n = notifier();
      await _flush();

      await n.send("  hello room  ");

      expect(state().messages.single["text"], "hello room",
          reason: "trimmed, and visible before the round trip");
      expect(lane.persisted.single["text"], "hello room");
      expect(lane.persisted.single["from"], "me");
      expect(lane.ephemeral, isEmpty);
    });

    test("an empty or whitespace-only send is a no-op", () async {
      final n = notifier();
      await _flush();

      await n.send("   ");

      expect(state().messages, isEmpty);
      expect(lane.persisted, isEmpty);
    });
  });

  group("catch-up replay", () {
    test("loads history WITHOUT marking any of it unread", () async {
      // Arriving to 200 messages of backlog and a "200" badge is noise.
      // Unread means "since you were last looking".
      lane.catchUpEvents = [
        _msg("casey", "one"),
        _msg("dana", "two"),
        _msg("casey", "three"),
      ];

      notifier();
      await _flush();

      expect(state().messages.length, 3);
      expect(state().unread, 0);
    });

    test("live messages after the replay DO count", () async {
      lane.catchUpEvents = [_msg("casey", "backlog")];
      notifier();
      await _flush();

      lane.pushInbound(_msg("dana", "live"));
      await _flush();

      expect(state().messages.length, 2);
      expect(state().unread, 1);
    });

    test("resolving after dispose does not write to a dead notifier", () async {
      final lane2 = FakeLane();
      final c2 = ProviderContainer(overrides: [
        laneServiceFactoryProvider.overrideWithValue((_) => lane2),
      ]);
      var disposed = false;
      addTearDown(() {
        if (!disposed) c2.dispose();
      });
      addTearDown(lane2.close);

      final pending = lane2.holdCatchUp();
      c2.read(spaceChatProvider(_args).notifier);

      c2.dispose();
      disposed = true;

      // The in-flight round trip arrives late, which is exactly what a user
      // backing out of a Space mid-join produces.
      pending.complete([_msg("casey", "late")]);
      await _flush();
      // Reaching here without throwing IS the assertion.
    });
  });

  test("leaving the Space cancels the lane subscription", () {
    final lane2 = FakeLane();
    final c2 = ProviderContainer(overrides: [
      laneServiceFactoryProvider.overrideWithValue((_) => lane2),
    ]);
    addTearDown(lane2.close);
    var disposed = false;
    addTearDown(() {
      if (!disposed) c2.dispose();
    });

    final sub = c2.listen(spaceChatProvider(_args), (_, _) {});
    c2.read(spaceChatProvider(_args).notifier);
    expect(lane2.hasListener, isTrue);

    sub.close();
    c2.dispose();
    disposed = true;

    // The old panel leaked one of these per open, for the life of the Space.
    expect(lane2.hasListener, isFalse);
  });

  group("preview redaction is detected, never configured", () {
    // Chef: "if you are broadcasting on a tv, you may not want the group
    // messages being displayed to everyone" and "can you detect if you are
    // airplaying or casting? if you are, then it only shows sender."
    test("ordinary session shows the message text", () {
      expect(mayShowMessageText(casting: false, screenSharing: false), isTrue);
    });

    test("casting redacts to sender-only", () {
      expect(mayShowMessageText(casting: true, screenSharing: false), isFalse);
    });

    test("screen sharing redacts too: the room is already watching", () {
      // The ordinary watch-party setup. A chat toast on a shared screen is as
      // public as one on the TV.
      expect(mayShowMessageText(casting: false, screenSharing: true), isFalse);
    });

    test("both at once still redacts", () {
      expect(mayShowMessageText(casting: true, screenSharing: true), isFalse);
    });

    test("the provider follows the live cast session", () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(chatPreviewMayShowTextProvider(false)), isTrue);

      c.read(activeCastSessionProvider.notifier).state =
          const HlsCastSession(egressId: "eg-1", hlsUrl: "https://x/y.m3u8");

      expect(c.read(chatPreviewMayShowTextProvider(false)), isFalse);
    });

    test("the provider redacts on screen share even with no cast", () {
      final c = ProviderContainer();
      addTearDown(c.dispose);

      expect(c.read(chatPreviewMayShowTextProvider(true)), isFalse);
    });
  });
}
