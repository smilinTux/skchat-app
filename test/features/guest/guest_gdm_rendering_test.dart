import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/guest/guest_room_screen.dart';
import 'package:skchat/services/guest_group_service.dart';
import 'package:skchat/services/guest_identity.dart';

/// guest-dm G6 (guest side): the guest is told, plainly, when their private
/// 1:1 grows into a group - a persistent banner, a live flip mid-session, a
/// who-is-here strip, and a local "so-and-so joined" line on later polls.

/// Static canned adapter (one fixed response per path) - copies the pattern
/// already established in guest_dm_room_affordances_test.dart.
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

/// Sequenced adapter: returns the next body in [responses] on each call to
/// `/api/v1/guest/conversation` (clamped to the last once exhausted), so a
/// test can simulate what the 3s poller sees change across ticks.
class _SeqAdapter implements HttpClientAdapter {
  _SeqAdapter(this.responses);
  final List<Map<String, dynamic>> responses;
  int calls = 0;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<List<int>>? rs, Future<void>? cf) async {
    final idx = calls < responses.length ? calls : responses.length - 1;
    calls++;
    return ResponseBody.fromString(jsonEncode(responses[idx]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }
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

Map<String, dynamic> _member(String uri, String name,
        {required bool guest, bool self = false}) =>
    {
      'identity_uri': uri,
      'display_name': name,
      'guest': guest,
      'self': self,
    };

final _selfMember = _member('guest:alice#deadbeef', 'Alice',
    guest: true, self: true);
final _hostMember =
    _member('capauth:lumina@skworld.io', 'Lumina', guest: false);
final _bobMember = _member('guest:bob#c0ffee', 'Bob', guest: true);

Future<GuestGroupService> _pumpRoom(
    WidgetTester tester, HttpClientAdapter adapter) async {
  final svc = GuestGroupService(
    dio: Dio()..httpClientAdapter = adapter,
    webuiBaseUrl: 'https://test.local',
    identity: _FakeIdentity(),
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [guestGroupServiceProvider.overrideWithValue(svc)],
    child: const MaterialApp(home: GuestRoomScreen(join: _join)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return svc;
}

void main() {
  testWidgets('banner is absent when the room is still a 1:1 (mode: dm)',
      (tester) async {
    await _pumpRoom(
      tester,
      _CannedAdapter({
        '/api/v1/guest/conversation': {
          'mode': 'dm',
          'members': [_selfMember, _hostMember],
          'messages': [],
        },
      }),
    );

    expect(find.textContaining('now a group chat'), findsNothing);

    await tester.pumpWidget(const SizedBox()); // cancel the poll timer
  });

  testWidgets('banner is present when the room is a group (mode: gdm)',
      (tester) async {
    await _pumpRoom(
      tester,
      _CannedAdapter({
        '/api/v1/guest/conversation': {
          'mode': 'gdm',
          'members': [_selfMember, _hostMember, _bobMember],
          'messages': [],
        },
      }),
    );

    expect(find.textContaining('now a group chat'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'banner appears after a poll tick when mode flips dm -> gdm mid-session',
      (tester) async {
    final adapter = _SeqAdapter([
      {
        'mode': 'dm',
        'members': [_selfMember, _hostMember],
        'messages': [],
      },
      {
        'mode': 'gdm',
        'members': [_selfMember, _hostMember, _bobMember],
        'messages': [],
      },
    ]);
    await _pumpRoom(tester, adapter);

    expect(find.textContaining('now a group chat'), findsNothing);

    // Advance past the 3s poll interval so _refresh fires again and picks up
    // the flipped mode - no reload/navigation, build() just re-reads _mode.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('now a group chat'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the member strip renders another guest as "guest: Bob"',
      (tester) async {
    await _pumpRoom(
      tester,
      _CannedAdapter({
        '/api/v1/guest/conversation': {
          'mode': 'gdm',
          'members': [_selfMember, _hostMember, _bobMember],
          'messages': [],
        },
      }),
    );

    expect(find.text('guest: Bob'), findsOneWidget);
    expect(find.text('host'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'a system line is appended when a new member shows up on a later poll, '
      'but NOT on first load', (tester) async {
    final adapter = _SeqAdapter([
      {
        'mode': 'gdm',
        'members': [_selfMember, _hostMember],
        'messages': [],
      },
      {
        'mode': 'gdm',
        'members': [_selfMember, _hostMember, _bobMember],
        'messages': [],
      },
    ]);
    await _pumpRoom(tester, adapter);

    // First load: Bob isn't in the room yet, so no join line - nothing to
    // diff against, and the guest didn't just watch anyone arrive.
    expect(find.textContaining('joined the room'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('guest: Bob joined the room.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
