import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:qr_flutter/qr_flutter.dart";
import "package:skchat/features/chats/invite_to_dm_sheet.dart";
import "package:skchat/features/spaces/space_share.dart";
import "package:skchat/services/guest_group_service.dart";

/// Canned Dio adapter with a configurable status, so a widget test can drive the
/// mint call to success (200) or a specific error (401/403/503) without a real
/// server. Records the last request for route/body assertions.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter({this.status = 200, this.body = const {}});
  final int status;
  final Map<String, Object?> body;
  RequestOptions? last;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<List<int>>? rs, Future<void>? cf) async {
    last = options;
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

GuestInviteService _service(_CannedAdapter adapter) =>
    GuestInviteService(dio: Dio()..httpClientAdapter = adapter,
        webuiBaseUrl: "https://h.test");

Widget _harness({
  required GuestInviteService service,
  NativeShareInvoker? shareInvoker,
}) {
  return ProviderScope(
    overrides: [
      guestInviteServiceProvider.overrideWithValue(service),
      if (shareInvoker != null)
        nativeShareInvokerProvider.overrideWithValue(shareInvoker),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showInviteToDmSheet(context),
            child: const Text("open"),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openAndCreate(WidgetTester tester) async {
  await tester.tap(find.text("open"));
  await tester.pumpAndSettle();
  await tester.tap(find.text("Create invite"));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("mint success -> result view shows the full link + QR + actions",
      (tester) async {
    final adapter = _CannedAdapter(body: {
      "token": "DM-TOK",
      "join_url": "/join/DM-TOK",
    });
    await tester.pumpWidget(_harness(service: _service(adapter)));
    await _openAndCreate(tester);

    // Posted to the mode=dm operator route with single_use default true.
    expect(adapter.last!.uri.path, "/api/v1/groups/dm/invite");
    expect(adapter.last!.uri.queryParameters["mode"], "dm");
    final sent = adapter.last!.data;
    final body = sent is String
        ? jsonDecode(sent) as Map<String, dynamic>
        : (sent as Map).cast<String, dynamic>();
    expect(body["single_use"], true);

    // Result view: absolute link, a QR, and the two share actions.
    expect(find.text("https://h.test/join/DM-TOK"), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text("Copy link"), findsOneWidget);
    expect(find.text("Share via..."), findsOneWidget);
  });

  testWidgets("reusable toggle flips single_use to false (my-DM-link)",
      (tester) async {
    final adapter = _CannedAdapter(body: {"join_url": "/join/DM-TOK"});
    await tester.pumpWidget(_harness(service: _service(adapter)));
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Reusable link"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Create invite"));
    await tester.pumpAndSettle();

    final sent = adapter.last!.data;
    final body = sent is String
        ? jsonDecode(sent) as Map<String, dynamic>
        : (sent as Map).cast<String, dynamic>();
    expect(body["single_use"], false);
    expect(body["reusable"], true);
  });

  testWidgets("403 -> honest operator-only permission message (not an outage)",
      (tester) async {
    await tester.pumpWidget(
        _harness(service: _service(_CannedAdapter(status: 403))));
    await _openAndCreate(tester);

    expect(find.textContaining("operator-only"), findsOneWidget);
    // Did not fall through to a result view.
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets("503 -> clear 'guest links are turned off' message",
      (tester) async {
    await tester.pumpWidget(
        _harness(service: _service(_CannedAdapter(status: 503))));
    await _openAndCreate(tester);

    expect(find.textContaining("Guest links are turned off"), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets("Share via... invokes the native share seam with the link text",
      (tester) async {
    var invoked = 0;
    String? captured;
    await tester.pumpWidget(_harness(
      service: _service(_CannedAdapter(body: {"join_url": "/join/DM-TOK"})),
      shareInvoker: (text, {subject}) async {
        invoked++;
        captured = text;
      },
    ));
    await _openAndCreate(tester);

    await tester.tap(find.text("Share via..."));
    await tester.pumpAndSettle();

    expect(invoked, 1);
    expect(captured, contains("https://h.test/join/DM-TOK"));
  });

  testWidgets("Copy link puts the full link on the clipboard", (tester) async {
    String? clipped;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == "Clipboard.setData") {
          clipped = (call.arguments as Map)["text"] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
        _harness(service: _service(_CannedAdapter(body: {"join_url": "/join/DM-TOK"}))));
    await _openAndCreate(tester);

    await tester.tap(find.text("Copy link"));
    await tester.pumpAndSettle();

    expect(clipped, "https://h.test/join/DM-TOK");
    expect(find.text("Link copied"), findsOneWidget);
  });
}
