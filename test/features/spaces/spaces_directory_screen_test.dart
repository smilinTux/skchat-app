import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:skchat/features/spaces/space_models.dart";
import "package:skchat/features/spaces/spaces_directory_screen.dart";
import "package:skchat/services/spaces_identity_service.dart";
import "package:skchat/services/spaces_service.dart";

/// This device's persisted Spaces id, standing in for
/// `SpacesIdentityService.ensure()`'s persisted `spaces_device_id` (a random
/// hex string in reality; a readable constant here for assertions).
const _myDeviceId = "device-aaaa1111";
const _otherHostFqid = "device-bbbb2222";

SpaceSummary _summary({
  required String id,
  required String title,
  String hostFqid = "host-device-id",
  bool recording = false,
}) {
  return SpaceSummary(
    spaceId: id,
    title: title,
    hostFqid: hostFqid,
    status: "live",
    speakers: const ["host-device-id"],
    recording: recording,
  );
}

/// A fixed Spaces identity used by tests, standing in for the persisted
/// per-device id + alias [SpacesIdentityService.ensure] would normally load.
class _FixedSpacesIdentityNotifier extends SpacesIdentityNotifier {
  _FixedSpacesIdentityNotifier(this._identity);

  final SpacesIdentity _identity;

  @override
  Future<SpacesIdentity> build() async => _identity;
}

/// Records every request path it sees and always answers 200 with an empty
/// (or per-route canned) JSON body, mirroring the adapter used in
/// spaces_service_test.dart.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);

  final Map<String, Object?> routes;
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
    // SpacesService builds the request with a full URL string (base + path)
    // rather than setting Dio's baseUrl, so `options.path` ends up holding the
    // whole URL; `options.uri.path` is the bit we actually want to assert on.
    requestedPaths.add(options.uri.path);
    requestedBodies.add(options.data);
    final body = routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Like [_CannedAdapter], but any request whose path is in [failPaths] throws
/// a DioException instead of responding, so tests can exercise the
/// join-host-403-falls-back-to-listener path.
class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter(this.routes, this.failPaths);

  final Map<String, Object?> routes;
  final Set<String> failPaths;
  final List<String> requestedPaths = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedPaths.add(options.uri.path);
    if (failPaths.contains(options.uri.path)) {
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 403),
        type: DioExceptionType.badResponse,
      );
    }
    final body = routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
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
      "identity": "whoever",
      "role": role,
      "token": "jwt-$role",
      "title": "Town Hall",
    };

GoRouter _router() {
  return GoRouter(
    initialLocation: "/spaces",
    routes: [
      GoRoute(
        path: "/spaces",
        builder: (context, state) => const SpacesDirectoryScreen(),
      ),
      GoRoute(
        path: "/spaces/:id",
        builder: (context, state) {
          final join = state.extra as SpaceJoin?;
          return Scaffold(
            body: Center(child: Text("ROOM:${join?.role ?? "none"}")),
          );
        },
      ),
    ],
  );
}

Widget _wrap(
  List<SpaceSummary> spaces, {
  required Dio dio,
  SpacesIdentity identity =
      const SpacesIdentity(id: _myDeviceId, displayName: "Casey"),
}) {
  return ProviderScope(
    overrides: [
      spacesDirectoryProvider.overrideWith((ref) => Stream.value(spaces)),
      spacesIdentityProvider
          .overrideWith(() => _FixedSpacesIdentityNotifier(identity)),
      spacesServiceProvider.overrideWithValue(
        SpacesService(dio: dio, webuiBaseUrl: "https://test.local"),
      ),
    ],
    child: MaterialApp.router(routerConfig: _router()),
  );
}

void main() {
  group("isHostOfSpace", () {
    const me = SpacesIdentity(id: _myDeviceId, displayName: "Casey");

    test("true when hostFqid matches this device's Spaces id", () {
      final space = _summary(id: "s1", title: "t", hostFqid: _myDeviceId);
      expect(isHostOfSpace(space, me), isTrue);
    });

    test("false when hostFqid belongs to a different device", () {
      final space = _summary(id: "s1", title: "t", hostFqid: _otherHostFqid);
      expect(isHostOfSpace(space, me), isFalse);
    });

    test("false when hostFqid is empty (unknown host)", () {
      final space = _summary(id: "s1", title: "t", hostFqid: "");
      expect(isHostOfSpace(space, me), isFalse);
    });

    test(
        "false even when displayName happens to match hostFqid: only the "
        "device id counts, never the (editable, non-unique) display name",
        () {
      final space = _summary(id: "s1", title: "t", hostFqid: "Casey");
      expect(isHostOfSpace(space, me), isFalse);
    });
  });

  group("SpacesDirectoryScreen join routing", () {
    testWidgets(
        "tapping Join on a Space I host calls joinHost, not joinListener",
        (tester) async {
      final adapter = _CannedAdapter({
        "/spaces/s1/join-host": _joinBody(role: "host"),
      });
      final dio = Dio()..httpClientAdapter = adapter;

      await tester.pumpWidget(_wrap(
        [_summary(id: "s1", title: "My Space", hostFqid: _myDeviceId)],
        dio: dio,
      ));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "Join"));
      await tester.pumpAndSettle();

      expect(adapter.requestedPaths, contains("/spaces/s1/join-host"));
      expect(adapter.requestedPaths, isNot(contains("/spaces/s1/join")));
      expect(find.text("ROOM:host"), findsOneWidget);
    });

    testWidgets(
        "tapping Join on someone else's Space calls joinListener with THIS "
        "device's id (no per-device suffix) and its display-name alias",
        (tester) async {
      final adapter = _CannedAdapter({
        "/spaces/s1/join": _joinBody(role: "listener"),
      });
      final dio = Dio()..httpClientAdapter = adapter;

      await tester.pumpWidget(_wrap(
        [_summary(id: "s1", title: "Their Space", hostFqid: _otherHostFqid)],
        dio: dio,
      ));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "Join"));
      await tester.pumpAndSettle();

      expect(adapter.requestedPaths, contains("/spaces/s1/join"));
      expect(adapter.requestedPaths, isNot(contains("/spaces/s1/join-host")));
      expect(find.text("ROOM:listener"), findsOneWidget);

      final body = adapter.requestedBodies.single as Map<String, dynamic>;
      // The exact device id, unsuffixed: it is already globally unique per
      // device, so two different people never collide on it.
      expect(body["identity"], _myDeviceId);
      expect(body["name"], "Casey");
    });

    testWidgets(
        "a device whose id does NOT equal a Space's hostFqid joins as a "
        "listener, never as host, even if it tries",
        (tester) async {
      final adapter = _CannedAdapter({
        "/spaces/s1/join": _joinBody(role: "listener"),
      });
      final dio = Dio()..httpClientAdapter = adapter;

      await tester.pumpWidget(_wrap(
        [_summary(id: "s1", title: "Their Space", hostFqid: _otherHostFqid)],
        dio: dio,
        identity: const SpacesIdentity(id: _myDeviceId, displayName: "Casey"),
      ));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "Join"));
      await tester.pumpAndSettle();

      expect(adapter.requestedPaths, isNot(contains("/spaces/s1/join-host")));
      expect(find.text("ROOM:listener"), findsOneWidget);
    });

    testWidgets(
        "when joinHost 403s for the Space's own host, falls back to joinListener",
        (tester) async {
      final adapter = _FlakyAdapter(
        {"/spaces/s1/join": _joinBody(role: "listener")},
        {"/spaces/s1/join-host"},
      );
      final dio = Dio()..httpClientAdapter = adapter;

      await tester.pumpWidget(_wrap(
        [_summary(id: "s1", title: "My Space", hostFqid: _myDeviceId)],
        dio: dio,
      ));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "Join"));
      await tester.pumpAndSettle();

      // Both endpoints were tried: joinHost first (and rejected), then the
      // listener fallback, which is what actually gets the user into the room.
      expect(adapter.requestedPaths, [
        "/spaces/s1/join-host",
        "/spaces/s1/join",
      ]);
      expect(find.text("ROOM:listener"), findsOneWidget);
      // No error snackbar: the fallback means the user still got in.
      expect(find.textContaining("Couldn't join"), findsNothing);
    });
  });

  group("SpacesDirectoryScreen create routing", () {
    testWidgets(
        "creating a Space sends THIS device's Spaces id as host_fqid, not "
        "the shared node identity",
        (tester) async {
      final adapter = _CannedAdapter({
        "/spaces/create": _joinBody(role: "host"),
      });
      final dio = Dio()..httpClientAdapter = adapter;

      await tester.pumpWidget(_wrap(const [], dio: dio));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "Start a Space"));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, "Town Hall");
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, "Go live"));
      await tester.pumpAndSettle();

      expect(adapter.requestedPaths, contains("/spaces/create"));
      final body = adapter.requestedBodies.single as Map<String, dynamic>;
      expect(body["host_fqid"], _myDeviceId);
      expect(find.text("ROOM:host"), findsOneWidget);
    });
  });

  testWidgets("renders both live Space titles + a REC badge", (tester) async {
    final dio = Dio()..httpClientAdapter = _CannedAdapter({});
    await tester.pumpWidget(_wrap(
      [
        _summary(id: "s1", title: "SKWorld Town Hall", recording: true),
        _summary(id: "s2", title: "Daily Standup"),
      ],
      dio: dio,
    ));
    await tester.pump();

    expect(find.text("SKWorld Town Hall"), findsOneWidget);
    expect(find.text("Daily Standup"), findsOneWidget);
    // The recording Space shows a REC badge; both show LIVE.
    expect(find.text("REC"), findsOneWidget);
    expect(find.text("LIVE"), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, "Join"), findsNWidgets(2));
  });

  testWidgets("shows empty state when no Spaces are live", (tester) async {
    final dio = Dio()..httpClientAdapter = _CannedAdapter({});
    await tester.pumpWidget(_wrap(const [], dio: dio));
    await tester.pump();
    expect(find.text("No live Spaces"), findsOneWidget);
  });
}
