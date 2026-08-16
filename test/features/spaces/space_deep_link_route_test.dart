// A SHARED Space link (`{base}/app/#/spaces/{id}`, see `spaceJoinUrl` in
// space_share.dart) carries ONLY the space id. It carries no `extra`, because
// `extra` is in-process router state that a URL cannot hold.
//
// The `/spaces/:id` route used to read `state.extra as SpaceJoin` (an
// unguarded cast), which is fine for in-app navigation from the Spaces
// directory (it hands over a freshly minted, role-scoped join) and throws a
// _TypeError for every shared link, so the page never built and the guest got
// a blank grey screen. Reproduced over CDP against the live deployment.
//
// These tests pump the app's REAL route builder ([spaceRoomPageBuilder], the
// exact function `appRouterProvider` wires at [AppRoutes.spaceRoom]) inside a
// minimal GoRouter, the house pattern for route-table widget tests (see
// skcode_module_mount_test.dart's header for why this beats pumping
// `appRouterProvider`, which hardcodes an initial location and drags in the
// Hive-backed onboarding redirect chain).
import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dio/dio.dart";
import "package:flutter/material.dart" hide ConnectionState;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:hive_flutter/hive_flutter.dart";
import "package:livekit_client/livekit_client.dart";
import "package:mocktail/mocktail.dart";
import "package:skchat/core/router/app_router.dart";
import "package:skchat/features/spaces/space_models.dart";
import "package:skchat/features/spaces/space_room_screen.dart";
import "package:skchat/features/spaces/watch_session.dart"
    show laneServiceFactoryProvider;
import "package:skchat/services/lane_service.dart" show LaneLike;
import "package:skchat/services/livekit_call_service.dart";
import "package:skchat/services/spaces_identity_service.dart";
import "package:skchat/services/spaces_service.dart";

class MockLiveKitCallService extends Mock implements LiveKitCallService {}

/// This device's persisted Spaces id (see [SpacesIdentityService]); a readable
/// constant here instead of the real 32 hex chars so assertions stay legible.
const _myDeviceId = "device-aaaa1111";
const _otherHostFqid = "device-bbbb2222";

/// A lane that answers instantly and never emits, so the room's Watch
/// Together session stays deterministic (mirrors space_room_screen_test.dart).
class _NoopLane implements LaneLike {
  @override
  Stream<Map<String, dynamic>> get inbound => const Stream.empty();

  @override
  Future<void> publish(Map<String, dynamic> payload) async {}

  @override
  Future<void> publishEphemeral(Map<String, dynamic> payload) async {}

  @override
  Future<List<Map<String, dynamic>>> catchUp(String lane) async => const [];
}

class _FixedSpacesIdentityNotifier extends SpacesIdentityNotifier {
  _FixedSpacesIdentityNotifier(this._identity);

  final SpacesIdentity _identity;

  @override
  Future<SpacesIdentity> build() async => _identity;
}

/// Answers 200 with a per-path canned JSON body, records every path it saw,
/// and throws a DioException for any path in [failPaths]. Same shape as
/// spaces_directory_screen_test.dart's adapters, merged into one so a single
/// test can both mint a join and fail one.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes, {this.failPaths = const {}, this.gate});

  final Map<String, Object?> routes;
  final Set<String> failPaths;

  /// When set, every response waits on this future, so a test can hold the
  /// join "in flight" and inspect the loading state deterministically.
  final Future<void>? gate;
  final List<String> requestedPaths = [];
  final List<Object?> requestedBodies = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // SpacesService builds a full URL string rather than setting Dio's
    // baseUrl, so `options.path` holds the whole URL; `options.uri.path` is
    // the bit worth asserting on.
    requestedPaths.add(options.uri.path);
    requestedBodies.add(options.data);
    if (gate != null) await gate;
    if (failPaths.contains(options.uri.path)) {
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 404),
        type: DioExceptionType.badResponse,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(routes[options.uri.path] ?? {}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

Map<String, Object?> _joinBody({required String role}) => {
      "space_id": "s1",
      "room": "sk-space-s1",
      "url": "wss://lk.test/ws",
      "identity": _myDeviceId,
      "role": role,
      "token": "jwt-$role",
      "title": "Town Hall",
    };

Map<String, Object?> _directoryBody({required String hostFqid}) => {
      "spaces": [
        {
          "space_id": "s1",
          "title": "Town Hall",
          "host_fqid": hostFqid,
          "status": "live",
          "speakers": [hostFqid],
          "recording": false,
        },
      ],
    };

const _inAppJoin = SpaceJoin(
  spaceId: "s1",
  room: "sk-space-s1",
  url: "wss://lk.test/ws",
  identity: _myDeviceId,
  role: "host",
  token: "jwt-host",
  title: "Town Hall",
);

void main() {
  late MockLiveKitCallService svc;
  late GoRouter router;

  setUpAll(() {
    // The room's share sheet watches backendConfigProvider, which opens a Hive
    // box best-effort on build and has no default path on the test VM.
    Hive.init(Directory.systemTemp.createTempSync("skchat_test_hive").path);
    registerFallbackValue(CameraPosition.front);
    registerFallbackValue(GlobalKey<State<StatefulWidget>>());
  });

  setUp(() {
    svc = MockLiveKitCallService();
    final participants = <LiveKitParticipantSnapshot>[];
    when(() => svc.participants).thenAnswer((_) => Stream.value(participants));
    when(() => svc.connectionState)
        .thenAnswer((_) => Stream.value(ConnectionState.connected));
    when(() => svc.currentParticipants).thenReturn(participants);
    when(() => svc.dataChannel).thenAnswer((_) => const Stream.empty());
    when(() => svc.micEnabledChanges).thenAnswer((_) => const Stream.empty());
    when(() => svc.isSharingSystemAudio).thenReturn(false);
    when(() => svc.externalMuteEvents)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => svc.connectWithToken(
          wsUrl: any(named: "wsUrl"),
          token: any(named: "token"),
        )).thenAnswer((_) async {});
    when(() => svc.setMicEnabled(any())).thenAnswer((_) async {});
    when(() => svc.leaveRoom()).thenAnswer((_) async {});
    when(() => svc.setScreenShareEnabled(any(),
        systemAudioDeviceId: any(named: "systemAudioDeviceId"),
        sourceId: any(named: "sourceId"))).thenAnswer((_) async {});
    when(() => svc.defaultSystemAudioSource()).thenAnswer((_) async => null);
    when(() => svc.setCameraEnabled(any(),
            cameraPosition: any(named: "cameraPosition")))
        .thenAnswer((_) async {});
    when(() => svc.switchCameraPosition(any())).thenAnswer((_) async {});
  });

  /// A router wired to the app's OWN [AppRoutes.spaceRoom] path constant and
  /// its REAL [spaceRoomPageBuilder]. `/spaces` stands in for the directory so
  /// the "back to Spaces" affordance has somewhere to land.
  Widget wrap(
    Dio dio, {
    SpacesIdentity identity =
        const SpacesIdentity(id: _myDeviceId, displayName: "Casey"),
  }) {
    router = GoRouter(
      initialLocation: "/spaces",
      routes: [
        GoRoute(
          path: "/spaces",
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text("DIRECTORY"))),
        ),
        GoRoute(
          path: AppRoutes.spaceRoom,
          pageBuilder: spaceRoomPageBuilder,
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        liveKitCallServiceProvider.overrideWithValue(svc),
        spacesServiceProvider.overrideWithValue(
          SpacesService(dio: dio, webuiBaseUrl: "https://test.local"),
        ),
        spacesIdentityProvider
            .overrideWith(() => _FixedSpacesIdentityNotifier(identity)),
        laneServiceFactoryProvider.overrideWithValue((args) => _NoopLane()),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets(
      "a shared deep link with NO extra mints its own listener join and "
      "enters the room instead of blanking", (tester) async {
    final adapter = _CannedAdapter({
      "/spaces": _directoryBody(hostFqid: _otherHostFqid),
      "/spaces/s1/join": _joinBody(role: "listener"),
    });
    await tester.pumpWidget(wrap(Dio()..httpClientAdapter = adapter));
    await tester.pump();

    // What a guest actually does: open the URL. No extra, ever.
    router.go(AppRoutes.spaceRoomPath("s1"));
    await tester.pumpAndSettle();

    expect(adapter.requestedPaths, contains("/spaces/s1/join"));
    expect(find.byType(SpaceRoomScreen), findsOneWidget);
    verify(() => svc.connectWithToken(
          wsUrl: "wss://lk.test/ws",
          token: "jwt-listener",
        )).called(1);
  });

  testWidgets(
      "a deep link shows a loading state while the join is in flight, never "
      "a blank frame", (tester) async {
    // Gate the mint on a Completer the test holds, so "in flight" is a real
    // state to look at rather than a race against how fast the canned
    // adapter's futures resolve.
    final gate = Completer<void>();
    final adapter = _CannedAdapter(
      {
        "/spaces": _directoryBody(hostFqid: _otherHostFqid),
        "/spaces/s1/join": _joinBody(role: "listener"),
      },
      gate: gate.future,
    );
    await tester.pumpWidget(wrap(Dio()..httpClientAdapter = adapter));
    await tester.pump();

    router.go(AppRoutes.spaceRoomPath("s1"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining("Joining"), findsOneWidget);
    expect(find.byType(SpaceRoomScreen), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SpaceRoomScreen), findsOneWidget);
  });

  testWidgets(
      "a deep link into a Space THIS device hosts mints a host token, not a "
      "listener one", (tester) async {
    final adapter = _CannedAdapter({
      "/spaces": _directoryBody(hostFqid: _myDeviceId),
      "/spaces/s1/join-host": _joinBody(role: "host"),
    });
    await tester.pumpWidget(wrap(Dio()..httpClientAdapter = adapter));
    await tester.pump();

    // The host reloading their own shared link loses `extra` exactly like a
    // guest does, so the role has to be re-derived, not assumed.
    router.go(AppRoutes.spaceRoomPath("s1"));
    await tester.pumpAndSettle();

    expect(adapter.requestedPaths, contains("/spaces/s1/join-host"));
    expect(adapter.requestedPaths, isNot(contains("/spaces/s1/join")));
    expect(find.byType(SpaceRoomScreen), findsOneWidget);
  });

  testWidgets(
      "in-app navigation that already carries a SpaceJoin extra still renders "
      "the room directly, with no second join call", (tester) async {
    final adapter = _CannedAdapter({});
    await tester.pumpWidget(wrap(Dio()..httpClientAdapter = adapter));
    await tester.pump();

    // Exactly what SpacesDirectoryScreen._join does after minting a join.
    router.go(AppRoutes.spaceRoomPath("s1"), extra: _inAppJoin);
    await tester.pumpAndSettle();

    expect(find.byType(SpaceRoomScreen), findsOneWidget);
    verify(() => svc.connectWithToken(
          wsUrl: "wss://lk.test/ws",
          token: "jwt-host",
        )).called(1);
    // The already-minted token is used as-is: no /spaces/s1/join round trip.
    expect(adapter.requestedPaths, isNot(contains("/spaces/s1/join")));
    expect(adapter.requestedPaths, isNot(contains("/spaces/s1/join-host")));
  });

  testWidgets(
      "a join failure (space ended, 404, offline) shows a readable error, "
      "never a blank screen", (tester) async {
    final adapter = _CannedAdapter(
      {"/spaces": _directoryBody(hostFqid: _otherHostFqid)},
      failPaths: {"/spaces/s1/join"},
    );
    await tester.pumpWidget(wrap(Dio()..httpClientAdapter = adapter));
    await tester.pump();

    router.go(AppRoutes.spaceRoomPath("s1"));
    await tester.pumpAndSettle();

    expect(find.byType(SpaceRoomScreen), findsNothing);
    expect(find.textContaining("Couldn't join"), findsOneWidget);
    // A way out, so the failure is a screen and not a dead end.
    expect(find.text("Try again"), findsOneWidget);
  });

  testWidgets(
      "a Space missing from the live directory still attempts a listener "
      "join: the server, not the directory, is the authority", (tester) async {
    // Directory empty (stale poll, filtered listing), join still succeeds.
    final adapter = _CannedAdapter({
      "/spaces": {"spaces": <Object?>[]},
      "/spaces/s1/join": _joinBody(role: "listener"),
    });
    await tester.pumpWidget(wrap(Dio()..httpClientAdapter = adapter));
    await tester.pump();

    router.go(AppRoutes.spaceRoomPath("s1"));
    await tester.pumpAndSettle();

    expect(adapter.requestedPaths, contains("/spaces/s1/join"));
    expect(find.byType(SpaceRoomScreen), findsOneWidget);
  });

  test("a Space room deep link is exempt from the first-run onboarding gate",
      () {
    // A guest handed a shared link has never onboarded. The Spaces TAB is a
    // normal in-app destination and must still be gated.
    expect(isGuestDeepLink(AppRoutes.spaceRoomPath("s1")), isTrue);
    expect(isGuestDeepLink(AppRoutes.spaces), isFalse);
  });
}
