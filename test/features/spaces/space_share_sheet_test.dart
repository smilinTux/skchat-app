import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:skchat/features/spaces/space_share.dart";
import "package:skchat/features/spaces/space_share_sheet.dart";
import "package:skchat/features/chats/chats_provider.dart";
import "package:skchat/models/conversation.dart";
import "package:skchat/services/skcomms_client.dart";
import "package:skchat/services/skcomms_sync.dart";

/// No-op sync notifier so the sheet's send call never spins up the real
/// daemon/PQC chain (mirrors FakeSyncNotifier in
/// conversation_history_reply_test.dart). Records every sendMessage call so
/// tests can assert on the peerId + content the sheet reused from the
/// existing chat-send path.
class FakeSyncNotifier extends SKCommsSyncNotifier {
  final List<({String peerId, String content})> calls = [];
  SendResult? nextResult = const SendResult(delivered: true, envelopeId: "e1");

  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.online);

  @override
  Future<SendResult?> sendMessage({
    required String peerId,
    required String content,
    String? threadId,
    String? inReplyTo,
    String? contentType,
    Map<String, dynamic>? rich,
  }) async {
    calls.add((peerId: peerId, content: content));
    return nextResult;
  }
}

/// Seeds [chatsProvider] with a fixed list, skipping the real notifier's
/// daemon polling (mirrors the FakeSyncNotifier pattern above).
class FakeChatsNotifier extends ChatsNotifier {
  FakeChatsNotifier(this._seed);
  final List<Conversation> _seed;

  @override
  List<Conversation> build() => _seed;
}

void main() {
  const spaceId = "s1";
  const title = "SKWorld Town Hall";

  final conversations = [
    Conversation(
      peerId: "lumina@chef.skworld",
      displayName: "Lumina",
      lastMessage: "hey",
      lastMessageTime: DateTime(2026, 1, 1),
      isAgent: true,
    ),
    Conversation(
      peerId: "ops-group",
      displayName: "Ops Group",
      lastMessage: "standup",
      lastMessageTime: DateTime(2026, 1, 1),
      isGroup: true,
    ),
  ];

  late FakeSyncNotifier syncNotifier;

  setUpAll(() {
    // backendConfigProvider (watched by the sheet for skchatWebuiUrl) opens a
    // Hive box best-effort on build; on the test VM Hive has no default path
    // without this, mirrors conversation_history_reply_test.dart.
    Hive.init(Directory.systemTemp.createTempSync("skchat_test_hive").path);
  });

  setUp(() {
    syncNotifier = FakeSyncNotifier();
  });

  Widget wrap({
    List<Override> extraOverrides = const [],
  }) {
    return ProviderScope(
      overrides: [
        chatsProvider.overrideWith(() => FakeChatsNotifier(conversations)),
        skcommsSyncProvider.overrideWith(() => syncNotifier),
        ...extraOverrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showShareSpaceSheet(
                context,
                spaceId: spaceId,
                title: title,
              ),
              child: const Text("open"),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester, {List<Override> overrides = const []}) async {
    await tester.pumpWidget(wrap(extraOverrides: overrides));
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
  }

  testWidgets("shows all three share rows", (tester) async {
    await openSheet(tester);

    expect(find.text("Share to skchat chat"), findsOneWidget);
    expect(find.text("Share via..."), findsOneWidget);
    expect(find.text("Copy link"), findsOneWidget);
  });

  testWidgets("Copy link puts the derived join URL on the clipboard",
      (tester) async {
    String? clipped;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == "Clipboard.setData") {
          clipped = (call.arguments as Map)["text"] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await openSheet(tester);
    await tester.tap(find.text("Copy link"));
    await tester.pumpAndSettle();

    expect(clipped, spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", spaceId));
    expect(find.text("Link copied"), findsOneWidget);
  });

  testWidgets(
      "Share to skchat chat opens the picker and sends through the normal "
      "chat send path with a message containing the join URL", (tester) async {
    await openSheet(tester);

    await tester.tap(find.text("Share to skchat chat"));
    await tester.pumpAndSettle();

    // Picker shows both the DM and the group from chatsProvider.
    expect(find.text("Lumina"), findsOneWidget);
    expect(find.text("Ops Group"), findsOneWidget);

    await tester.tap(find.text("Lumina"));
    await tester.pumpAndSettle();

    expect(syncNotifier.calls, hasLength(1));
    expect(syncNotifier.calls.single.peerId, "lumina@chef.skworld");
    expect(
      syncNotifier.calls.single.content,
      contains(spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", spaceId)),
    );
    expect(syncNotifier.calls.single.content, contains(title));
  });

  testWidgets(
      "Share via... invokes the share_plus seam with the join text",
      (tester) async {
    var invoked = 0;
    String? capturedText;
    String? capturedSubject;

    await openSheet(tester, overrides: [
      nativeShareInvokerProvider.overrideWithValue(
        (text, {subject}) async {
          invoked++;
          capturedText = text;
          capturedSubject = subject;
        },
      ),
    ]);

    await tester.tap(find.text("Share via..."));
    await tester.pumpAndSettle();

    expect(invoked, 1);
    expect(
      capturedText,
      contains(spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", spaceId)),
    );
    expect(capturedSubject, title);
  });

  testWidgets(
      "Share via... with NO share target (MissingPluginException, e.g. Linux "
      "desktop) silently falls back to clipboard with 'Link copied'",
      (tester) async {
    String? clipped;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == "Clipboard.setData") {
          clipped = (call.arguments as Map)["text"] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await openSheet(tester, overrides: [
      nativeShareInvokerProvider.overrideWithValue(
        (text, {subject}) async =>
            throw MissingPluginException("no share target"),
      ),
    ]);

    await tester.tap(find.text("Share via..."));
    await tester.pumpAndSettle();

    expect(clipped, spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", spaceId));
    expect(find.text("Link copied"), findsOneWidget);
    expect(find.text("Share failed, link copied instead"), findsNothing);
  });

  testWidgets(
      "Share via... with an UnimplementedError (no platform implementation) "
      "also silently falls back to clipboard with 'Link copied'",
      (tester) async {
    String? clipped;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == "Clipboard.setData") {
          clipped = (call.arguments as Map)["text"] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await openSheet(tester, overrides: [
      nativeShareInvokerProvider.overrideWithValue(
        (text, {subject}) async => throw UnimplementedError("no impl"),
      ),
    ]);

    await tester.tap(find.text("Share via..."));
    await tester.pumpAndSettle();

    expect(clipped, spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", spaceId));
    expect(find.text("Link copied"), findsOneWidget);
    expect(find.text("Share failed, link copied instead"), findsNothing);
  });

  testWidgets(
      "Share via... with a REAL failure (any other exception) copies the "
      "link but surfaces 'Share failed, link copied instead'", (tester) async {
    String? clipped;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == "Clipboard.setData") {
          clipped = (call.arguments as Map)["text"] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await openSheet(tester, overrides: [
      nativeShareInvokerProvider.overrideWithValue(
        (text, {subject}) async => throw Exception("platform blew up"),
      ),
    ]);

    await tester.tap(find.text("Share via..."));
    await tester.pumpAndSettle();

    expect(clipped, spaceJoinUrl("https://noroc2027.tail204f0c.ts.net", spaceId));
    expect(find.text("Share failed, link copied instead"), findsOneWidget);
    expect(find.text("Link copied"), findsNothing);
  });
}
