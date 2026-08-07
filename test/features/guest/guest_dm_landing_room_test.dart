import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/guest/guest_landing_screen.dart";
import "package:skchat/features/guest/guest_invite_inactive.dart";
import "package:skchat/features/guest/guest_room_screen.dart";
import "package:skchat/services/guest_group_service.dart";
import "package:skchat/services/guest_identity.dart";

/// Canned adapter keyed by path, with an optional per-path status so a test can
/// drive a route to 403 (revoked). Records every request for assertions.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes, {this.status = const {}});
  final Map<String, Object?> routes;
  final Map<String, int> status;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<List<int>>? rs, Future<void>? cf) async {
    requests.add(options);
    final path = options.uri.path;
    final body = routes[options.path] ?? routes[path] ?? {};
    return ResponseBody.fromString(
      jsonEncode(body),
      status[path] ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class _FakeIdentity implements GuestIdentity {
  _FakeIdentity({bool cached = false}) : _cached = cached;
  bool _cached;
  @override
  Future<bool> hasCached() async => _cached;
  @override
  Future<GuestKeypair> ensure() async {
    _cached = true;
    return const GuestKeypair(publicKeyB64: "PUB", fingerprint: "deadbeef");
  }

  @override
  Future<String> sign(String data) async => "SIG";
  @override
  Future<void> clear() async => _cached = false;
}

GuestGroupService _svc(_CannedAdapter a) => GuestGroupService(
      dio: Dio()..httpClientAdapter = a,
      webuiBaseUrl: "https://test.local",
      identity: _FakeIdentity(),
    );

Widget _wrap(GuestGroupService svc, Widget child) => ProviderScope(
      overrides: [guestGroupServiceProvider.overrideWithValue(svc)],
      child: MaterialApp(home: child),
    );

GuestJoinResult _joinResult() => const GuestJoinResult(
      sessionToken: "S",
      guestId: "guest:alice#deadbeef",
      displayName: "Alice",
      groupId: "g1",
      groupName: "DM with Lumina",
      trust: "untrusted",
      callAvailable: false,
    );

void main() {
  testWidgets("mode=dm landing shows DM copy + operator name + chat icon",
      (tester) async {
    final adapter = _CannedAdapter({
      "/api/v1/guest/invite/TOK": {
        "valid": true,
        "mode": "dm",
        "operator_name": "Lumina",
        "group_name": "dm-abc",
      },
    });
    await tester.pumpWidget(_wrap(_svc(adapter),
        const GuestLandingScreen(token: "TOK")));
    await tester.pumpAndSettle();

    expect(find.text("You're invited to chat with"), findsOneWidget);
    expect(find.text("Lumina"), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.groups_2_outlined), findsNothing);
  });

  testWidgets("group landing keeps the group copy + groups icon", (tester) async {
    final adapter = _CannedAdapter({
      "/api/v1/guest/invite/TOK": {
        "valid": true,
        "group_name": "Town Hall",
      },
    });
    await tester.pumpWidget(_wrap(_svc(adapter),
        const GuestLandingScreen(token: "TOK")));
    await tester.pumpAndSettle();

    expect(find.text("You're invited to"), findsOneWidget);
    expect(find.text("Town Hall"), findsOneWidget);
    expect(find.byIcon(Icons.groups_2_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);
  });

  testWidgets("self-rename POSTs /guest/name and swaps to the reminted token",
      (tester) async {
    final adapter = _CannedAdapter({
      "/api/v1/guest/conversation": {"messages": <Object?>[]},
      "/api/v1/guest/name": {
        "ok": true,
        "display_name": "Bob",
        "session_token": "S2",
      },
    });
    await tester.pumpWidget(_wrap(_svc(adapter),
        GuestRoomScreen(join: _joinResult(), isDm: true, operatorName: "Lumina")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // DM header shows the operator name.
    expect(find.text("Lumina"), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Change my name"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, "Bob");
    await tester.tap(find.text("Save"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final nameReq =
        adapter.requests.firstWhere((r) => r.uri.path == "/api/v1/guest/name");
    expect(nameReq.method, "POST");
    expect((nameReq.data as Map)["display_name"], "Bob");

    // The 3s poll after the rename must carry the REMINTED token, proving the
    // swap (else the rename silently reverts server-side).
    adapter.requests.clear();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 50));
    final poll = adapter.requests
        .lastWhere((r) => r.uri.path == "/api/v1/guest/conversation");
    expect(poll.headers["Authorization"], "Bearer S2");

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a contact_revoked 403 swaps the room for the inactive view",
      (tester) async {
    final adapter = _CannedAdapter(
      {
        "/api/v1/guest/conversation": {
          "detail": {"reason": "contact_revoked"}
        },
      },
      status: {"/api/v1/guest/conversation": 403},
    );
    await tester.pumpWidget(
        _wrap(_svc(adapter), GuestRoomScreen(join: _joinResult())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(GuestInviteInactiveView), findsOneWidget);
    expect(find.text("This invite is no longer active"), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
