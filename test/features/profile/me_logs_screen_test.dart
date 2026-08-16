// Tests for lib/features/profile/me_logs_screen.dart, the Me > Logs
// screen: the local diag ring buffer ("recent problems") rendered
// independently of `GET /api/v1/health` ("service health"), with the
// honesty rules from health_service.dart's header actually visible on
// screen (never green unverified; unknown is visually distinct from both
// up and down; the data's own timestamp is always shown; the problems
// list never depends on the network call).
//
// MUTATION TARGETS (see PR description for the actual mutate-and-report
// run against these three, by name):
//   1. "an unreachable server renders every known service as not verified,
//      never up" -- mutating HealthService's 404/unreachable branch to
//      return an all-`up` HealthAvailable instead of HealthUnavailable
//      turns this red.
//   2. "up and unknown render with visually distinct icon and color" --
//      mutating _ServiceRow's `unknown` case in me_logs_screen.dart to
//      reuse the `up` case's icon/color turns this red.
//   3. "the recent-problems list renders before the health fetch ever
//      resolves" -- mutating _MeLogsScreenState.initState to gate
//      `_loadEventsSnapshot`/`_subscribeToNewEvents` behind `_loadHealth()`
//      completing turns this red.
import "dart:async";
import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/features/profile/me_logs_screen.dart";
import "package:skchat/services/diag/diag_event.dart";
import "package:skchat/services/diag/diag_log.dart";
import "package:skchat/services/diag/diag_log_provider.dart";
import "package:skchat/services/health_service.dart";

const _jsonHeaders = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

/// Serves a fixed `/api/v1/health` response body + status.
class _FixedHealthAdapter implements HttpClientAdapter {
  _FixedHealthAdapter({this.body = const {}});
  final Object body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(jsonEncode(body), 200, headers: _jsonHeaders);
  }
}

/// Simulates a genuinely unreachable server: the request never completes.
/// Used to prove the problems list renders WITHOUT waiting on this call
/// (mutation target 3), never merely "resolves fast with an error".
class _HangingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return Completer<ResponseBody>().future; // never completes
  }
}

class _ErrorAdapter implements HttpClientAdapter {
  _ErrorAdapter(this.statusCode);
  final int? statusCode;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: statusCode == null
          ? DioExceptionType.connectionError
          : DioExceptionType.badResponse,
      response: statusCode == null
          ? null
          : Response(requestOptions: options, statusCode: statusCode),
    );
  }
}

HealthService _health(HttpClientAdapter adapter) =>
    HealthService(dio: Dio()..httpClientAdapter = adapter, webuiBaseUrl: "https://h.test");

/// A [DiagLog] for a test to use. [DiagLog.emit] always schedules a 30 s
/// debounce [Timer] (even memory-only, with `init()` never called); a test
/// that calls `emit` MUST `await` [DiagLog.dispose] on this before its body
/// returns (NOT merely via `addTearDown`: flutter_test's pending-timer
/// invariant check runs immediately after the test body completes, before
/// `addTearDown` callbacks fire, so a timer only cancelled there still trips
/// "A Timer is still pending even after the widget tree was disposed").
/// `addTearDown` is registered anyway as a backstop for a test that forgets,
/// or exits early via a failed expectation.
DiagLog _diagLog() {
  final log = DiagLog();
  addTearDown(log.dispose);
  return log;
}

Widget _wrap({required HealthService health, required DiagLog diagLog}) {
  return ProviderScope(
    overrides: [
      healthServiceProvider.overrideWithValue(health),
      diagLogProvider.overrideWithValue(diagLog),
    ],
    child: const MaterialApp(home: MeLogsScreen()),
  );
}

DiagEvent _emitFailedRequest(
  DiagLog log, {
  String host = "skworld-100",
  int port = 18794,
}) {
  return log.emit(
    level: DiagLevel.error,
    category: DiagCategory.net,
    code: "net.request_failed",
    fields: {
      "kind": NetFailureKind.connectTimeout,
      "host": host,
      "port": port,
      "pathTemplate": "/stt/transcribe",
      "method": "POST",
      "durationMs": 1200,
    },
  )!;
}

void main() {
  group("service health", () {
    testWidgets(
      "an up/down/unknown mix renders three distinct state words and the "
      "data's own timestamp",
      (tester) async {
        final adapter = _FixedHealthAdapter(body: {
          "generated_at": "2026-08-16T12:00:00Z",
          "services": [
            {
              "id": "stt",
              "label": "Speech to text",
              "state": "up",
              "checked_at": "2026-08-16T12:00:00Z",
            },
            {
              "id": "llm",
              "label": "Language model",
              "state": "down",
              "checked_at": "2026-08-16T12:00:00Z",
            },
            {
              "id": "tts",
              "label": "Text to speech",
              "state": "unknown",
              "checked_at": "2026-08-16T12:00:00Z",
            },
          ],
        });

        await tester.pumpWidget(
          _wrap(health: _health(adapter), diagLog: _diagLog()),
        );
        await tester.pumpAndSettle();

        expect(find.text("Speech to text"), findsOneWidget);
        expect(find.text("reachable"), findsOneWidget);
        expect(find.text("not reachable"), findsOneWidget);
        expect(find.text("not verified"), findsOneWidget);
        expect(find.textContaining("Data as of"), findsOneWidget);
        expect(find.byKey(const Key("health-unavailable-banner")), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "an unreachable server renders every known service as not verified, "
      "never up, and says the app cannot reach the server",
      (tester) async {
        await tester.pumpWidget(
          _wrap(health: _health(_ErrorAdapter(null)), diagLog: _diagLog()),
        );
        await tester.pumpAndSettle();

        // Every one of the 5 known services renders "not verified"; none
        // renders "reachable" or "not reachable" -- this is the assertion
        // mutation target 1 is meant to redden.
        expect(find.text("not verified"), findsNWidgets(kKnownServiceIds.length));
        expect(find.text("reachable"), findsNothing);
        expect(find.text("not reachable"), findsNothing);
        expect(find.byKey(const Key("health-unavailable-banner")), findsOneWidget);
        expect(find.textContaining("can't reach the server"), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "a 404 (not yet deployed) also renders every service unknown, with "
      "wording distinct from the unreachable case",
      (tester) async {
        await tester.pumpWidget(
          _wrap(health: _health(_ErrorAdapter(404)), diagLog: _diagLog()),
        );
        await tester.pumpAndSettle();

        expect(find.text("not verified"), findsNWidgets(kKnownServiceIds.length));
        expect(find.text("reachable"), findsNothing);
        expect(
          find.textContaining("doesn't support service health checks yet"),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      "up and unknown render with visually distinct icon and color",
      (tester) async {
        final adapter = _FixedHealthAdapter(body: {
          "generated_at": "2026-08-16T12:00:00Z",
          "services": [
            {
              "id": "stt",
              "label": "Speech to text",
              "state": "up",
              "checked_at": "2026-08-16T12:00:00Z",
            },
            {
              "id": "llm",
              "label": "Language model",
              "state": "unknown",
              "checked_at": "2026-08-16T12:00:00Z",
            },
          ],
        });

        await tester.pumpWidget(
          _wrap(health: _health(adapter), diagLog: _diagLog()),
        );
        await tester.pumpAndSettle();

        final upIcon = tester.widget<Icon>(
          find.byKey(const Key("service-icon-stt")),
        );
        final unknownIcon = tester.widget<Icon>(
          find.byKey(const Key("service-icon-llm")),
        );

        // This is the assertion mutation target 2 is meant to redden:
        // reusing the `up` icon+color for `unknown` collapses both of
        // these to the same values.
        expect(upIcon.icon == unknownIcon.icon, isFalse);
        expect(upIcon.color == unknownIcon.color, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets("a per-row Semantics label states the service and its "
        "state in words, not just color", (tester) async {
      final adapter = _FixedHealthAdapter(body: {
        "generated_at": "2026-08-16T12:00:00Z",
        "services": [
          {
            "id": "stt",
            "label": "Speech to text",
            "state": "down",
            "checked_at": "2026-08-16T12:00:00Z",
          },
        ],
      });

      await tester.pumpWidget(
        _wrap(health: _health(adapter), diagLog: _diagLog()),
      );
      await tester.pumpAndSettle();

      final semantics = tester.getSemantics(find.text("Speech to text").first);
      expect(semantics.label, contains("Speech to text"));
      expect(semantics.label, contains("not reachable"));
    });
  });

  group("recent problems", () {
    testWidgets("an empty ring buffer shows a plain 'nothing wrong' state, "
        "not a blank box", (tester) async {
      await tester.pumpWidget(
        _wrap(health: _health(_FixedHealthAdapter(body: const {"services": []})),
            diagLog: _diagLog()),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key("problems-empty-state")), findsOneWidget);
      expect(find.text("Nothing has gone wrong recently"), findsOneWidget);
    });

    testWidgets("a net.request_failed event renders a plain-language line, "
        "newest first, and expands to show technical detail", (tester) async {
      final diagLog = _diagLog();
      _emitFailedRequest(diagLog, host: "skworld-100", port: 18794);
      final second = diagLog.emit(
        level: DiagLevel.error,
        category: DiagCategory.net,
        code: "net.request_failed",
        fields: {
          "kind": NetFailureKind.refused,
          "host": "skworld-41",
          "port": 9384,
          "pathTemplate": "/api/v1/devices",
          "method": "GET",
          "durationMs": 3,
        },
      )!;

      await tester.pumpWidget(
        _wrap(
          health: _health(_FixedHealthAdapter(body: const {"services": []})),
          diagLog: diagLog,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("Speech to text"), findsOneWidget);
      expect(find.textContaining("skworld-41:9384"), findsOneWidget);

      // Newest first: the second-emitted event (skworld-41, seq 1) renders
      // ABOVE the first-emitted one (skworld-100, seq 0).
      final newestOffset =
          tester.getTopLeft(find.byKey(Key("diag-event-${second.seq}")));
      final oldestOffset =
          tester.getTopLeft(find.byKey(const Key("diag-event-0")));
      expect(newestOffset.dy, lessThan(oldestOffset.dy));

      // Tap-to-expand reveals the technical detail (never shown collapsed).
      expect(find.textContaining("kind: connectTimeout"), findsNothing);
      await tester.tap(find.textContaining("Speech to text"));
      await tester.pumpAndSettle();
      expect(find.textContaining("kind: connectTimeout"), findsOneWidget);
      expect(find.textContaining("host: skworld-100"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await diagLog.dispose();
    });

    testWidgets("an info-level lifecycle event is not a 'problem' and does "
        "not appear in the list", (tester) async {
      final diagLog = _diagLog();
      diagLog.emit(
        level: DiagLevel.info,
        category: DiagCategory.lifecycle,
        code: "lifecycle.start",
        fields: {"buildId": "b1"},
      );

      await tester.pumpWidget(
        _wrap(
          health: _health(_FixedHealthAdapter(body: const {"services": []})),
          diagLog: diagLog,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key("problems-empty-state")), findsOneWidget);
      expect(find.textContaining("App started"), findsNothing);
      await diagLog.dispose();
    });

    testWidgets(
      "the recent-problems list renders before the health fetch ever "
      "resolves (a hung/unreachable server never blocks it)",
      (tester) async {
        final diagLog = _diagLog();
        _emitFailedRequest(diagLog);

        await tester.pumpWidget(
          _wrap(health: _health(_HangingAdapter()), diagLog: diagLog),
        );
        // Deliberately NOT pumpAndSettle: the health fetch never completes,
        // so settling would hang. A couple of plain frames is enough for
        // the synchronous ring-buffer read in initState to have rendered.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.textContaining("Speech to text"), findsOneWidget);
        // The health section is still honestly loading, not stuck showing
        // stale/fabricated data.
        expect(find.byKey(const Key("health-card-loading")), findsOneWidget);
        await diagLog.dispose();
      },
    );
  });
}
