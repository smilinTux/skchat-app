import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/guest_group_mint_sheet.dart';
import 'package:skchat/services/guest_group_service.dart';

/// Records requests; returns a join_url so a mint surfaces a link.
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<List<int>>? rs, Future<void>? cf) async {
    requests.add(o);
    return ResponseBody.fromString(
        jsonEncode({'token': 'T', 'join_url': '/join/T'}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }
}

GuestInviteService _svc(_Adapter a) => GuestInviteService(
    dio: Dio()..httpClientAdapter = a, webuiBaseUrl: 'https://h.test');

Widget _harness(_Adapter a, Future<void> Function(BuildContext) open) {
  return ProviderScope(
    overrides: [guestInviteServiceProvider.overrideWithValue(_svc(a))],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('promote: confirm dialog spells out the group change; Cancel mints nothing',
      (tester) async {
    final a = _Adapter();
    await tester.pumpWidget(_harness(
        a, (c) => showAddGuestToDmSheet(c, groupId: 'g-existing')));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Security-sensitive confirm copy.
    expect(find.text('Add another guest?'), findsOneWidget);
    expect(find.textContaining('will become a group'), findsOneWidget);
    expect(find.textContaining('NOT be able to read earlier'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(a.requests, isEmpty);
  });

  testWidgets('promote: confirm -> per-person mint posts mode=dm against THIS group',
      (tester) async {
    final a = _Adapter();
    await tester.pumpWidget(_harness(
        a, (c) => showAddGuestToDmSheet(c, groupId: 'g-existing')));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add guest'));
    await tester.pumpAndSettle();

    // Promote sheet does NOT offer a shared link (per-person only).
    expect(find.text('Create a per-person invite'), findsOneWidget);
    expect(find.text('Create one shared link'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Bestie');
    await tester.tap(find.text('Create a per-person invite'));
    await tester.pumpAndSettle();

    final req = a.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.path, '/api/v1/groups/g-existing/invite');
    expect(req.uri.queryParameters['mode'], 'dm');
    final body = req.data is String
        ? jsonDecode(req.data as String) as Map<String, dynamic>
        : (req.data as Map).cast<String, dynamic>();
    expect(body['alias'], 'Bestie');

    // The minted link is shown.
    expect(find.textContaining('https://h.test/join/T'), findsOneWidget);
  });
}
