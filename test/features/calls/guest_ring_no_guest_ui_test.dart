// guest-dm G7: "guests never see ring UI" pinned structurally. GuestRingBanner
// reads guestRingProvider (which watches the OPERATOR-side chatsProvider) and
// is mounted only inside AppShellScaffold (see app_shell.dart) - the guest
// route `/g/:token` (GuestLandingScreen -> GuestRoomScreen) is a top-level
// GoRoute outside that shell (see app_router.dart) and never references it.
// This test proves the negative concretely: build the actual guest room tree
// and confirm no GuestRingBanner is anywhere in it, using the same canned-Dio
// harness as guest_room_call_button_test.dart so it stays cheap (no real
// daemon, no chatsProvider override needed since the guest tree never reads
// it).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/calls/guest_ring.dart';
import 'package:skchat/features/guest/guest_room_screen.dart';
import 'package:skchat/services/guest_group_service.dart';
import 'package:skchat/services/guest_identity.dart';

class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);
  final Map<String, Object?> routes;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

class _FakeIdentity implements GuestIdentity {
  bool _cached = false;

  @override
  Future<bool> hasCached() async => _cached;

  @override
  Future<GuestKeypair> ensure() async {
    _cached = true;
    return const GuestKeypair(publicKeyB64: 'PUB', fingerprint: 'deadbeefdeadbeef');
  }

  @override
  Future<String> sign(String data) async => 'SIG';

  @override
  Future<void> clear() async {
    _cached = false;
  }
}

GuestJoinResult _join() => const GuestJoinResult(
      sessionToken: 'S',
      guestId: 'guest:alice#deadbeefdeadbeef',
      displayName: 'Alice',
      groupId: 'g1',
      groupName: 'Town Hall',
      trust: 'untrusted',
      callAvailable: false,
    );

void main() {
  testWidgets(
      'GuestRingBanner never appears in the guest room tree (guests never '
      'see the operator ring UI)', (tester) async {
    final adapter = _CannedAdapter({
      '/api/v1/guest/conversation': {'messages': <Object?>[]},
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final svc = GuestGroupService(
        dio: dio, webuiBaseUrl: 'https://test.local', identity: _FakeIdentity());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [guestGroupServiceProvider.overrideWithValue(svc)],
        child: MaterialApp(home: GuestRoomScreen(join: _join())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(GuestRingBanner), findsNothing);
    expect(find.textContaining('Incoming'), findsNothing);

    // Tear down cleanly so the 3s poll Timer is cancelled (dispose()).
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
