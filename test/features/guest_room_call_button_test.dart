import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/guest/guest_room_screen.dart";
import "package:skchat/services/guest_group_service.dart";
import "package:skchat/services/guest_identity.dart";

/// Canned-response adapter keyed by path; records every request for assertions.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);
  final Map<String, Object?> routes;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = routes[options.path] ?? routes[options.uri.path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Deterministic in-test identity (no WebCrypto / secure-storage).
class _FakeIdentity implements GuestIdentity {
  bool _cached = false;

  @override
  Future<bool> hasCached() async => _cached;

  @override
  Future<GuestKeypair> ensure() async {
    _cached = true;
    return const GuestKeypair(publicKeyB64: "PUB", fingerprint: "deadbeefdeadbeef");
  }

  @override
  Future<String> sign(String data) async => "SIG";

  @override
  Future<void> clear() async {
    _cached = false;
  }
}

GuestJoinResult _join() => const GuestJoinResult(
      sessionToken: "S",
      guestId: "guest:alice#deadbeefdeadbeef",
      displayName: "Alice",
      groupId: "g1",
      groupName: "Town Hall",
      trust: "untrusted",
      // No pre-minted call token -> the button MUST mint via /guest/call.
      callAvailable: false,
    );

void main() {
  testWidgets("composer renders a call button near the message input",
      (tester) async {
    final adapter = _CannedAdapter({
      "/api/v1/guest/conversation": {"messages": <Object?>[]},
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final svc = GuestGroupService(
        dio: dio, webuiBaseUrl: "https://test.local", identity: _FakeIdentity());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [guestGroupServiceProvider.overrideWithValue(svc)],
        child: MaterialApp(home: GuestRoomScreen(join: _join())),
      ),
    );
    await tester.pump(); // settle the initial conversation refresh
    await tester.pump(const Duration(milliseconds: 50)); // flush dio stream

    // A dedicated call affordance sits next to the composer input.
    expect(find.byTooltip("Start call"), findsOneWidget);
    expect(find.byIcon(Icons.call_outlined), findsOneWidget);

    // Tear down cleanly so the 3s poll Timer is cancelled (dispose()).
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      "tapping call mints via /guest/call and surfaces the unavailable state",
      (tester) async {
    final adapter = _CannedAdapter({
      "/api/v1/guest/conversation": {"messages": <Object?>[]},
      // Server has no LiveKit creds -> degrade shape; no room to navigate to.
      "/api/v1/guest/call": {"available": false, "room": "gcall-xyz"},
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final svc = GuestGroupService(
        dio: dio, webuiBaseUrl: "https://test.local", identity: _FakeIdentity());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [guestGroupServiceProvider.overrideWithValue(svc)],
        child: MaterialApp(home: GuestRoomScreen(join: _join())),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip("Start call"));
    await tester.pump(); // enter loading state
    await tester.pump(const Duration(milliseconds: 50)); // resolve the mint
    await tester.pump(); // render the snackbar

    // The mint route was hit, bearing the guest session token.
    final callReq =
        adapter.requests.firstWhere((r) => r.uri.path == "/api/v1/guest/call");
    expect(callReq.method, "POST");
    expect(callReq.headers["Authorization"], "Bearer S");

    // available:false -> the error state, not a navigation into the call UI.
    expect(find.text("The call is not available right now."), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
