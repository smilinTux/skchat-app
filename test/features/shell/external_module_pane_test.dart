import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/core/modules/external_modules.dart';
import 'package:skchat/core/modules/module_manifest.dart';
import 'package:skchat/features/shell/external_module_pane.dart';
import 'package:skchat/services/daemon_config.dart';
import 'package:skchat/services/embed_token_service.dart';
import 'package:skchat/services/skcomms_client.dart';

/// Scripted mint-endpoint adapter: returns [tokens] in order (one per hit,
/// the last one repeats), each with its own `expires_at`, and counts hits so
/// a test can assert a proactive refresh actually re-hit the backend.
/// Mirrors `embed_token_service_test.dart`'s adapter shape.
class _EmbedTokenAdapter implements HttpClientAdapter {
  _EmbedTokenAdapter(this.responses);

  final List<Map<String, dynamic>> responses;
  int hitCount = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = responses[hitCount < responses.length ? hitCount : responses.length - 1];
    hitCount++;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// Stub the daemon-URL notifier so the pane resolves an origin without opening
/// Hive in a widget test.
class _StubDaemonConfig extends DaemonConfigNotifier {
  @override
  String build() => 'https://test.local';
}

const _manifest = ModuleManifest(
  id: 'skdashboard',
  title: 'Dashboard',
  icon: Icons.dashboard,
  route: '/external/skdashboard',
  external: true,
  externalEntryUrl: '/skdashboard',
  grade: 'B',
);

/// Pump [ExternalModulePane] for `skdashboard` with the daemon URL stubbed and
/// a real [EmbedTokenService] wired to [adapter], so the pane's own scheduling
/// logic (real `Timer`s, virtualized by `flutter_test`'s fake-async pump) runs
/// unmodified. The manifest lookup is overridden directly so discovery never
/// needs a network round-trip.
Future<void> _pumpPane(WidgetTester tester, _EmbedTokenAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final service = EmbedTokenService(client: SKCommsClient(dio: dio));

  await tester.pumpWidget(ProviderScope(
    overrides: [
      daemonUrlProvider.overrideWith(_StubDaemonConfig.new),
      externalModuleByIdProvider('skdashboard').overrideWithValue(_manifest),
      embedTokenServiceProvider.overrideWithValue(service),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ExternalModulePane(moduleId: 'skdashboard')),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mints a token and frames it into the embed url', (tester) async {
    final future = DateTime.now().toUtc().add(const Duration(minutes: 30));
    final adapter = _EmbedTokenAdapter([
      {'token': 'TOK-1', 'module': 'skdashboard', 'expires_at': future.toIso8601String()},
    ]);

    await _pumpPane(tester, adapter);

    // On the (non-web) test VM the embed is the host-URL stub, which renders
    // the resolved URL as selectable text: assert the token landed on it.
    expect(find.textContaining('/skdashboard?embed_token=TOK-1'), findsOneWidget);
    expect(adapter.hitCount, 1);
  });

  testWidgets(
      'proactively re-mints ~60s before the real expiry and reloads the '
      'frame with the fresh token, without waiting for the old one to lapse',
      (tester) async {
    // First mint expires in 100s -> proactive refresh fires at 100-60 = 40s,
    // well inside the >=30s "trust the real delay" floor, and far short of
    // the 20-minute unknown-expiry fallback -- keeps the test fast.
    final firstExpiry = DateTime.now().toUtc().add(const Duration(seconds: 100));
    final secondExpiry = DateTime.now().toUtc().add(const Duration(minutes: 30));
    final adapter = _EmbedTokenAdapter([
      {'token': 'TOK-1', 'module': 'skdashboard', 'expires_at': firstExpiry.toIso8601String()},
      {'token': 'TOK-2', 'module': 'skdashboard', 'expires_at': secondExpiry.toIso8601String()},
    ]);

    await _pumpPane(tester, adapter);
    expect(find.textContaining('embed_token=TOK-1'), findsOneWidget);
    expect(adapter.hitCount, 1);

    // Elapse past the scheduled refresh (40s) but well before the first
    // token's real expiry (100s), so a still-showing-TOK-1 frame here would
    // prove the refresh never fired.
    await tester.pump(const Duration(seconds: 41));
    // Let the invalidated FutureProvider's re-mint round-trip settle.
    await tester.pumpAndSettle();

    expect(adapter.hitCount, 2);
    expect(find.textContaining('embed_token=TOK-2'), findsOneWidget);
    expect(find.textContaining('embed_token=TOK-1'), findsNothing);
  });

  testWidgets('a refresh mint failure degrades to tokenless, not a crash',
      (tester) async {
    final firstExpiry = DateTime.now().toUtc().add(const Duration(seconds: 100));
    final adapter = _EmbedTokenAdapter([
      {'token': 'TOK-1', 'module': 'skdashboard', 'expires_at': firstExpiry.toIso8601String()},
      // Malformed second response (no token): mint() resolves to null rather
      // than throwing, and the pane's data branch frames the bare url.
      {'module': 'skdashboard'},
    ]);

    await _pumpPane(tester, adapter);
    expect(find.textContaining('embed_token=TOK-1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 41));
    await tester.pumpAndSettle();

    expect(adapter.hitCount, 2);
    // Tokenless degrade: the bare module url, no query param, no crash.
    expect(find.text('https://test.local/skdashboard'), findsOneWidget);
  });
}
