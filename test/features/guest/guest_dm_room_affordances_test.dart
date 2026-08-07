import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/guest/guest_room_screen.dart';
import 'package:skchat/services/guest_group_service.dart';
import 'package:skchat/services/guest_identity.dart';

/// guest-dm C5 (part 3/4): the shipped-default call + file affordances are
/// present in the guest's own mode=dm room, so a web guest can call and share.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.routes);
  final Map<String, Object?> routes;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<List<int>>? rs, Future<void>? cf) async =>
      ResponseBody.fromString(jsonEncode(routes[o.uri.path] ?? {}), 200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
}

class _FakeIdentity implements GuestIdentity {
  @override
  Future<bool> hasCached() async => true;
  @override
  Future<GuestKeypair> ensure() async =>
      const GuestKeypair(publicKeyB64: 'PUB', fingerprint: 'deadbeef');
  @override
  Future<String> sign(String data) async => 'SIG';
  @override
  Future<void> clear() async {}
}

const _join = GuestJoinResult(
  sessionToken: 'S',
  guestId: 'guest:alice#deadbeef',
  displayName: 'Alice',
  groupId: 'g-dm',
  groupName: 'dm-abc',
  trust: 'untrusted',
  callAvailable: false,
);

void main() {
  testWidgets('guest mode=dm room shows call + attach affordances',
      (tester) async {
    final svc = GuestGroupService(
      dio: Dio()
        ..httpClientAdapter =
            _CannedAdapter({'/api/v1/guest/conversation': {'messages': []}}),
      webuiBaseUrl: 'https://test.local',
      identity: _FakeIdentity(),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [guestGroupServiceProvider.overrideWithValue(svc)],
      child: const MaterialApp(
        home: GuestRoomScreen(join: _join),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Both call affordances + file attach are present in the guest DM room.
    expect(find.byTooltip('Join call'), findsOneWidget);
    expect(find.byTooltip('Start call'), findsOneWidget);
    expect(find.byTooltip('Attach file'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // cancel the poll timer
  });
}
