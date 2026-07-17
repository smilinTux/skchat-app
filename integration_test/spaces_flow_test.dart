// SP5: first autonomous integration_test harness for the skchat app.
//
// Drives the REAL app shell (SKChatApp -> GoRouter -> AppShell bottom nav ->
// SpacesDirectoryScreen -> SpaceRoomScreen) in-process on a real device
// (`flutter test integration_test -d linux`), replacing coordinate-guessing
// xdotool runs with deterministic widget-finder driving.
//
// Boundary strategy (do not fake-pass):
//   The suite drives the real widget tree and the real router. It stops at
//   exactly two network seams, the same Riverpod seams the widget tests use:
//
//     1. spacesServiceProvider / spacesDirectoryProvider: the sovereign
//        /spaces REST API. Seeded with one canned live Space so the
//        directory list and the Join flow are deterministic without the
//        SKChat web UI running.
//     2. liveKitCallServiceProvider: the LiveKit SFU connection. A mocktail
//        mock records connectWithToken(wsUrl, token) so the test PROVES the
//        room screen initiates the connection with the role-scoped join
//        token, which is the exact boundary where a live server would take
//        over.
//
//   Everything else (Hive persistence, skcomms sync polling, identity
//   providers, theming, navigation) is the real production object graph.
//
// Server-backed extension point:
//   Run with `--dart-define=SKCHAT_IT_LIVE=true` (the runner script maps
//   env SKCHAT_IT_LIVE=1 to this) to drop the two fakes. In live mode the
//   fake-seeded tests are skipped; a future live suite adds a test that
//   creates a Space through the real /spaces API and asserts real LiveKit
//   room state instead of the mock verification below.

import "dart:async";

import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:integration_test/integration_test.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/data/hive_adapters.dart";
import "package:skchat/features/spaces/space_models.dart";
import "package:skchat/features/spaces/spaces_directory_screen.dart";
import "package:skchat/main.dart";
import "package:skchat/services/livekit_call_service.dart";
import "package:skchat/services/spaces_service.dart";

/// True when the harness runs against a live SKChat web UI + LiveKit server
/// (`--dart-define=SKCHAT_IT_LIVE=true`). See the header comment.
const bool kLiveBackend = bool.fromEnvironment("SKCHAT_IT_LIVE");

class MockSpacesService extends Mock implements SpacesService {}

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

const _seededSpace = SpaceSummary(
  spaceId: "it-space-1",
  title: "IT Harness Space",
  hostFqid: "host@dk.skworld",
  status: "live",
  speakers: ["host@dk.skworld"],
  recording: false,
);

const _seededJoin = SpaceJoin(
  spaceId: "it-space-1",
  room: "sk-space-it-space-1",
  url: "wss://livekit.invalid/ws",
  identity: "it-listener",
  role: "listener",
  token: "jwt-it-listener",
  title: "IT Harness Space",
);

/// Pump frames for [duration] in fixed steps. The app shell hosts continuous
/// animations (shimmer placeholders, speaking pulse rings), so pumpAndSettle
/// would never settle; bounded pumping is the deterministic alternative.
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  const step = Duration(milliseconds: 100);
  var elapsed = Duration.zero;
  while (elapsed < duration) {
    await tester.pump(step);
    elapsed += step;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Mirror main()'s persistence bootstrap. On a real device path_provider
    // is available, so this is the production Hive setup, not a shim.
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(chatMessageTypeId)) {
      Hive.registerAdapter(ChatMessageAdapter());
    }
    if (!Hive.isAdapterRegistered(conversationTypeId)) {
      Hive.registerAdapter(ConversationAdapter());
    }
  });

  late MockSpacesService spacesSvc;
  late MockLiveKitCallService livekitSvc;

  setUp(() {
    spacesSvc = MockSpacesService();
    livekitSvc = MockLiveKitCallService();

    // The Spaces REST seam: joining the seeded Space hands back the canned
    // role-scoped join envelope, echoing whatever per-device identity the
    // directory screen minted.
    when(() => spacesSvc.listLive()).thenAnswer((_) async => [_seededSpace]);
    when(() => spacesSvc.joinListener(
          any(),
          identity: any(named: "identity"),
          name: any(named: "name"),
        )).thenAnswer((_) async => _seededJoin);

    // The LiveKit seam: everything the SpaceRoomScreen consumes, stubbed at
    // the connection boundary exactly like test/features/spaces widget tests.
    final participants = <LiveKitParticipantSnapshot>[
      const LiveKitParticipantSnapshot(
        identity: "host@dk.skworld",
        isLocal: false,
        isMuted: false,
        isCameraEnabled: false,
        isSpeaking: true,
        canPublish: true,
      ),
      const LiveKitParticipantSnapshot(
        identity: "it-listener",
        isLocal: true,
        isMuted: true,
        isCameraEnabled: false,
      ),
    ];
    when(() => livekitSvc.participants)
        .thenAnswer((_) => Stream.value(participants));
    when(() => livekitSvc.connectionState)
        .thenAnswer((_) => Stream.value(ConnectionState.connected));
    when(() => livekitSvc.currentParticipants).thenReturn(participants);
    when(() => livekitSvc.dataChannel).thenAnswer((_) => const Stream.empty());
    when(() => livekitSvc.micEnabledChanges)
        .thenAnswer((_) => const Stream.empty());
    when(() => livekitSvc.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).thenAnswer((_) async {});
    when(() => livekitSvc.setMicEnabled(any())).thenAnswer((_) async {});
    when(() => livekitSvc.leaveRoom()).thenAnswer((_) async {});
  });

  /// The full production app with ONLY the two network seams overridden.
  /// In live mode there are no overrides at all: the real services talk to
  /// the real backends.
  Widget app() {
    return ProviderScope(
      overrides: kLiveBackend
          ? const []
          : [
              spacesServiceProvider.overrideWithValue(spacesSvc),
              // Replace the 5s polling StreamProvider with a single seeded
              // emission so frames stay deterministic (the real provider
              // loops forever, which is correct in production but makes a
              // test frame budget unbounded).
              spacesDirectoryProvider
                  .overrideWith((ref) => Stream.value([_seededSpace])),
              liveKitCallServiceProvider.overrideWithValue(livekitSvc),
            ],
      child: const SKChatApp(),
    );
  }

  testWidgets("app boots to first frame without exception", (tester) async {
    await tester.pumpWidget(app());
    await pumpFor(tester, const Duration(seconds: 2));

    expect(find.byType(MaterialApp), findsOneWidget);
    // The real shell rendered: all five bottom-nav tabs are present.
    for (final label in ["Chats", "Spaces", "Activity", "Ops", "Me"]) {
      expect(find.text(label), findsWidgets, reason: "$label tab missing");
    }
  });

  testWidgets("bottom nav navigates to the Spaces directory", (tester) async {
    await tester.pumpWidget(app());
    await pumpFor(tester, const Duration(seconds: 2));

    await tester.tap(find.text("Spaces"));
    await pumpFor(tester, const Duration(seconds: 1));

    // The directory surface is up (screen type + its create affordance,
    // which renders in every backend state: list, empty and error).
    expect(find.byType(SpacesDirectoryScreen), findsOneWidget);
    expect(find.text("New Space"), findsWidgets);

    if (!kLiveBackend) {
      // Seeded directory content is deterministic in fake mode.
      expect(find.text("IT Harness Space"), findsOneWidget);
      expect(find.text("LIVE"), findsOneWidget);
      expect(find.text("Join"), findsOneWidget);
    }
  });

  testWidgets(
    "joining a Space drives the real router into the room screen and "
    "initiates the LiveKit connection with the role token (the server "
    "boundary)",
    (tester) async {
      await tester.pumpWidget(app());
      await pumpFor(tester, const Duration(seconds: 2));

      await tester.tap(find.text("Spaces"));
      await pumpFor(tester, const Duration(seconds: 1));
      expect(find.text("IT Harness Space"), findsOneWidget);

      await tester.tap(find.text("Join"));
      // Join REST roundtrip + route push transition + post-frame connect.
      await pumpFor(tester, const Duration(seconds: 2));

      // The directory called the Spaces API with the per-device identity.
      final captured = verify(() => spacesSvc.joinListener(
            captureAny(),
            identity: captureAny(named: "identity"),
            name: captureAny(named: "name"),
          )).captured;
      expect(captured[0], "it-space-1");
      expect(captured[1], isNotEmpty);

      // Room screen rendered from the real route (/spaces/:id via extra).
      expect(find.text("IT Harness Space"), findsWidgets);
      expect(find.text("SPEAKERS"), findsOneWidget);
      expect(find.text("LISTENERS"), findsOneWidget);
      // Listener role: raise hand control, never a hot mic.
      expect(find.text("Raise hand"), findsOneWidget);
      verifyNever(() => livekitSvc.setMicEnabled(true));

      // THE connection boundary: the screen handed the role-scoped token to
      // the LiveKit service. A live server run continues past this point.
      verify(() => livekitSvc.connectWithToken(
            wsUrl: _seededJoin.url,
            token: _seededJoin.token,
          )).called(1);
    },
    skip: kLiveBackend,
  );
}
