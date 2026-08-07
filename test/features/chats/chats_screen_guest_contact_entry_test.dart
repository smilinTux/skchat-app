import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/chats/chats_screen.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/guest_dm_contacts_service.dart';
import 'package:skchat/services/identity_service.dart';

/// guest-dm C4/G7 gap-fill: card C4 built the operator contact sheet
/// (rename/expiry/mute/revoke) but no caller ever opened it for a plain 1:1
/// guest DM (only G7's gdm roster row got a caller). These tests cover the
/// long-press entry point wired onto ChatsScreen's rows.

/// Stub chats notifier: returns a fixed seed with NO microtask (avoids Hive /
/// daemon I/O in a widget test) and counts [refresh] calls so a test can
/// prove the sheet's `onChanged` callback actually reaches the chats list.
class _FakeChatsNotifier extends ChatsNotifier {
  _FakeChatsNotifier(this._seed);
  final List<Conversation> _seed;
  int refreshCalls = 0;

  @override
  List<Conversation> build() => _seed;

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }
}

/// Canned Dio adapter for GuestDmContactsService: serves `contacts` for the
/// S4 listing GET and records every request. Mirrors the pattern in
/// test/features/groups/group_info_screen_test.dart.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.contacts = const []});
  final List<Map<String, dynamic>> contacts;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    requests.add(options);
    if (options.method == 'GET' &&
        options.path.endsWith('/guest-dm/contacts')) {
      return ResponseBody.fromString(
          jsonEncode({'contacts': contacts}), 200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          });
    }
    return ResponseBody.fromString(jsonEncode(const {}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

Map<String, dynamic> _body(Object? data) => data is String
    ? jsonDecode(data) as Map<String, dynamic>
    : (data as Map).cast<String, dynamic>();

Conversation _guestDm1to1({
  String peerId = 'g-1',
  String guestName = 'Mallory',
  String? alias,
}) =>
    Conversation(
      peerId: peerId,
      displayName: 'dm-raw-group-name',
      lastMessage: 'hi',
      lastMessageTime: DateTime(2026, 8, 6, 12),
      isGroup: true,
      isGuestDm: true,
      guestName: guestName,
      guestAlias: alias,
      guestStatus: 'active',
    );

Conversation _gdm({String peerId = 'g-2'}) => Conversation(
      peerId: peerId,
      displayName: 'Fishing Trip Crew',
      lastMessage: 'see you at the dock',
      lastMessageTime: DateTime(2026, 8, 6, 12),
      isGroup: true,
      isGuestDm: true,
      mode: 'gdm',
      memberCount: 3,
    );

Conversation _normalDm() => Conversation(
      peerId: 'p-1',
      displayName: 'Lumina',
      lastMessage: 'hey',
      lastMessageTime: DateTime(2026, 8, 6, 12),
    );

Conversation _normalGroup() => Conversation(
      peerId: 'grp-1',
      displayName: 'Team',
      lastMessage: 'yo',
      lastMessageTime: DateTime(2026, 8, 6, 12),
      isGroup: true,
      memberCount: 4,
    );

Widget _harness({
  required _FakeChatsNotifier notifier,
  required GuestDmContactsService svc,
}) {
  final router = GoRouter(
    initialLocation: AppRoutes.chats,
    routes: [
      GoRoute(
        path: AppRoutes.chats,
        builder: (_, __) => const ChatsScreen(),
        routes: [
          GoRoute(
            path: ':peerId',
            builder: (_, state) => Scaffold(
              body: Text('THREAD:${state.pathParameters['peerId']}'),
            ),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      chatsProvider.overrideWith(() => notifier),
      identityKeyPairProvider.overrideWith((ref) async => null),
      // The native ChatsScreen's toolbar watches node capabilities; stub it
      // so no Dio network call leaves a pending timer in the test.
      nodeCapabilitiesProvider.overrideWith((ref) async => null),
      guestDmContactsServiceProvider.overrideWithValue(svc),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

GuestDmContactsService _svc(HttpClientAdapter a) => GuestDmContactsService(
    dio: Dio()..httpClientAdapter = a, webuiBaseUrl: 'https://h.test');

void main() {
  setUpAll(() {
    // Some provider chains open Hive during build; seed a throwaway dir so no
    // HiveError is thrown even though our stubs avoid Hive directly.
    Hive.init(Directory.systemTemp.createTempSync('skchat_chats_hive').path);
  });

  testWidgets(
      'long-press on a 1:1 guest DM row opens the C4 contact sheet, matched '
      'by group_id (the conversation peerId IS the dm_contacts group_id)',
      (tester) async {
    final adapter = _RecordingAdapter(contacts: const [
      {'fp': 'FP1', 'guest_name': 'Mallory', 'group_id': 'g-1'},
    ]);
    final notifier = _FakeChatsNotifier([_guestDm1to1(peerId: 'g-1')]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('guest: Mallory'));
    await tester.pumpAndSettle();

    expect(find.text('Private alias'), findsOneWidget);
    // No groupId is passed for a 1:1: the per-group action must not appear.
    expect(find.text('Remove from this group'), findsNothing);
    expect(
        find.textContaining('apply to this person everywhere'), findsNothing);

    final getReq =
        adapter.requests.firstWhere((r) => r.path.endsWith('/guest-dm/contacts'));
    expect(getReq.method, 'GET');
  });

  testWidgets(
      'long-press on a gdm row does NOT open the sheet (G7 roster is the '
      'right surface for several guests)', (tester) async {
    final adapter = _RecordingAdapter();
    final notifier = _FakeChatsNotifier([_gdm()]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Fishing Trip Crew'));
    await tester.pumpAndSettle();

    expect(find.text('Private alias'), findsNothing);
    expect(adapter.requests, isEmpty);
  });

  testWidgets('long-press on an ordinary 1:1 does NOT open the sheet',
      (tester) async {
    final adapter = _RecordingAdapter();
    final notifier = _FakeChatsNotifier([_normalDm()]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Lumina'));
    await tester.pumpAndSettle();

    expect(find.text('Private alias'), findsNothing);
    expect(adapter.requests, isEmpty);
  });

  testWidgets('long-press on an ordinary group does NOT open the sheet',
      (tester) async {
    final adapter = _RecordingAdapter();
    final notifier = _FakeChatsNotifier([_normalGroup()]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Team'));
    await tester.pumpAndSettle();

    expect(find.text('Private alias'), findsNothing);
    expect(adapter.requests, isEmpty);
  });

  testWidgets(
      'an alias rename through the sheet fires the refresh callback so the '
      'chats list is not left stale until the next poll', (tester) async {
    final adapter = _RecordingAdapter(contacts: const [
      {'fp': 'FP1', 'guest_name': 'Mallory', 'group_id': 'g-1'},
    ]);
    final notifier = _FakeChatsNotifier([_guestDm1to1(peerId: 'g-1')]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('guest: Mallory'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Alex from expo');
    await tester.tap(find.byTooltip('Save alias'));
    await tester.pumpAndSettle();

    final patchReq = adapter.requests.firstWhere((r) => r.method == 'PATCH');
    expect(patchReq.uri.path, '/api/v1/guest-dm/contacts/FP1');
    expect(_body(patchReq.data)['alias'], 'Alex from expo');
    expect(notifier.refreshCalls, 1);
  });

  testWidgets(
      'a revoke through the sheet fires the refresh callback and closes '
      'the sheet', (tester) async {
    final adapter = _RecordingAdapter(contacts: const [
      {'fp': 'FP1', 'guest_name': 'Mallory', 'group_id': 'g-1'},
    ]);
    final notifier = _FakeChatsNotifier([_guestDm1to1(peerId: 'g-1')]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('guest: Mallory'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Revoke access'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();

    final postReq = adapter.requests.firstWhere((r) => r.method == 'POST');
    expect(postReq.uri.path, '/api/v1/guest-dm/contacts/FP1/revoke');
    expect(notifier.refreshCalls, 1);
    expect(find.text('Revoke access'), findsNothing); // sheet closed
  });

  testWidgets(
      'a lookup failure (daemon offline) shows an honest error instead of '
      'opening a sheet with no real identity', (tester) async {
    final adapter = _FailingAdapter();
    final notifier = _FakeChatsNotifier([_guestDm1to1(peerId: 'g-1')]);

    await tester.pumpWidget(_harness(notifier: notifier, svc: _svc(adapter)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('guest: Mallory'));
    await tester.pumpAndSettle();

    expect(find.text('Private alias'), findsNothing);
    expect(find.textContaining('Could not load'), findsOneWidget);
  });
}

/// A Dio adapter that always errors, simulating the daemon being offline for
/// the initial `listContacts()` lookup.
class _FailingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? rs,
      Future<void>? cf) async {
    throw DioException(requestOptions: options, message: 'offline');
  }
}
