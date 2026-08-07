import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/guest_contact_sheet.dart';
import 'package:skchat/services/guest_dm_contacts_service.dart';

/// Records every request so tests can assert the S4 route + body.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  int status = 200;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<List<int>>? rs, Future<void>? cf) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(const {}), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

GuestDmContactsService _service(_RecordingAdapter a) => GuestDmContactsService(
    dio: Dio()..httpClientAdapter = a, webuiBaseUrl: 'https://h.test');

const _contact = GuestContact(
  fp: 'FP1',
  guestName: 'Mallory',
  alias: null,
  groupId: 'g1',
);

Widget _harness(
  _RecordingAdapter a, {
  int changes = 0,
  String? groupId,
  bool groupMembershipRevoked = false,
  VoidCallback? onChanged,
}) {
  return ProviderScope(
    overrides: [
      guestDmContactsServiceProvider.overrideWithValue(_service(a)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showGuestContactSheet(
              context,
              contact: _contact,
              groupId: groupId,
              groupMembershipRevoked: groupMembershipRevoked,
              onChanged: onChanged,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Map<String, dynamic> _body(Object? data) => data is String
    ? jsonDecode(data) as Map<String, dynamic>
    : (data as Map).cast<String, dynamic>();

void main() {
  testWidgets('alias rename round-trips through PATCH /guest-dm/contacts/{fp}',
      (tester) async {
    final a = _RecordingAdapter();
    await tester.pumpWidget(_harness(a));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Alex from expo');
    await tester.tap(find.byTooltip('Save alias'));
    await tester.pumpAndSettle();

    final req = a.requests.single;
    expect(req.method, 'PATCH');
    expect(req.uri.path, '/api/v1/guest-dm/contacts/FP1');
    expect(_body(req.data)['alias'], 'Alex from expo');
  });

  testWidgets('mute toggle PATCHes muted:true', (tester) async {
    final a = _RecordingAdapter();
    await tester.pumpWidget(_harness(a));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final req = a.requests.single;
    expect(req.method, 'PATCH');
    expect(_body(req.data)['muted'], true);
  });

  testWidgets('Revoke requires confirmation, then POSTs the revoke route',
      (tester) async {
    final a = _RecordingAdapter();
    await tester.pumpWidget(_harness(a));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tapping Revoke opens a confirm dialog; cancelling makes NO request.
    await tester.tap(find.text('Revoke access'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke access?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(a.requests, isEmpty);

    // Confirming POSTs the revoke route.
    await tester.tap(find.text('Revoke access'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();

    final req = a.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.path, '/api/v1/guest-dm/contacts/FP1/revoke');
  });

  testWidgets('an operator-only 403 surfaces an honest message', (tester) async {
    final a = _RecordingAdapter()..status = 403;
    await tester.pumpWidget(_harness(a));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'x');
    await tester.tap(find.byTooltip('Save alias'));
    await tester.pumpAndSettle();

    expect(find.textContaining('operator-only'), findsOneWidget);
  });

  group('guest-dm G7: per-group context', () {
    testWidgets(
        '1:1 path (no groupId) is unchanged: no "Remove from this group" '
        'button and no person-level note', (tester) async {
      final a = _RecordingAdapter();
      await tester.pumpWidget(_harness(a));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Remove from this group'), findsNothing);
      expect(
          find.textContaining('apply to this person everywhere'), findsNothing);
    });

    testWidgets(
        'opened with a groupId shows the person-level note and the scoped '
        'action', (tester) async {
      final a = _RecordingAdapter();
      await tester.pumpWidget(_harness(a, groupId: 'g-1'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Remove from this group'), findsOneWidget);
      expect(
          find.textContaining('apply to this person everywhere'),
          findsOneWidget);
      // Both actions are offered side by side, never one replacing the other.
      expect(find.text('Revoke access'), findsOneWidget);
    });

    testWidgets(
        'the two confirm dialogs are worded so they cannot be confused: '
        'per-group says other conversations survive, person-level says '
        'every conversation ends', (tester) async {
      final a = _RecordingAdapter();
      await tester.pumpWidget(_harness(a, groupId: 'g-1'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Remove from this group'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from this group?'), findsOneWidget);
      expect(find.textContaining('this group only'), findsOneWidget);
      expect(find.textContaining('keep working'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Revoke access'));
      await tester.pumpAndSettle();
      expect(find.text('Revoke access?'), findsOneWidget);
      expect(find.textContaining('every conversation with you'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(a.requests, isEmpty);
    });

    testWidgets(
        'confirming the per-group remove POSTs group_id, closes the sheet, '
        'and fires onChanged so the roster refreshes immediately',
        (tester) async {
      final a = _RecordingAdapter();
      var changed = 0;
      await tester.pumpWidget(
          _harness(a, groupId: 'g-1', onChanged: () => changed++));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Remove from this group'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      final req = a.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/api/v1/guest-dm/contacts/FP1/revoke');
      expect(_body(req.data)['group_id'], 'g-1');
      expect(changed, 1);
      // The sheet closes on success, same idiom as the person-level revoke.
      expect(find.text('Remove from this group'), findsNothing);
    });

    testWidgets('a membership already revoked pre-disables the scoped action',
        (tester) async {
      final a = _RecordingAdapter();
      await tester.pumpWidget(
          _harness(a, groupId: 'g-1', groupMembershipRevoked: true));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Remove from this group'),
        matching: find.byType(OutlinedButton),
      ));
      expect(button.onPressed, isNull);
    });
  });
}
