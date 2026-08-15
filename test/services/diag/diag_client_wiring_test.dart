// Proves the diag interceptor (diag_interceptor.dart) is actually attached
// to the daemon Dio clients it is supposed to be, per card 0a5b8e07: a
// failing request through each client must produce exactly one
// `net.request_failed` DiagEvent on the global sink.
//
// MUTATION TARGET, one group per client: removing that client's
// `_dio.interceptors.add(buildDiagInterceptor(emitDiagEvent));` line turns
// its group's test red (see the PR description for the actual
// comment-out-and-rerun this file's tests were checked against).
//
// A canned adapter that answers every request with a 503 is used throughout:
// dio's default `validateStatus` turns any non-2xx into a `DioException`
// (type badResponse), which is exactly what drives `buildDiagInterceptor`'s
// `onError` -- the same mechanism `diag_interceptor_test.dart`'s own
// "http4xx carries the status code" test already exercises end-to-end.
import "dart:convert";

import "package:dio/dio.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/device_list_service.dart";
import "package:skchat/services/diag/diag_error_sink.dart";
import "package:skchat/services/diag/diag_event.dart";
import "package:skchat/services/pq_prekey_service.dart";
import "package:skchat/services/skcapstone_client.dart";
import "package:skchat/services/skcomms_client.dart";

class _FailingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({"error": "service unavailable"}),
      503,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  setUp(() {
    diagEventSink = null;
  });

  tearDown(() {
    diagEventSink = null;
  });

  group("SKCommsClient", () {
    test("a failing request records one net.request_failed event", () async {
      final events = <DiagEvent>[];
      diagEventSink = events.add;
      final adapter = _FailingAdapter();
      final client = SKCommsClient(
        baseUrl: "http://api.skworld.test:9384",
        dio: Dio()..httpClientAdapter = adapter,
      );

      await client.isAlive();

      expect(adapter.requests, isNotEmpty);
      expect(events, hasLength(1));
      expect(events.single.code, "net.request_failed");
      expect(events.single.fields["host"], "api.skworld.test");
      expect(events.single.fields["status"], 503);
    });
  });

  group("DeviceListService", () {
    test("a failing request records one net.request_failed event", () async {
      final events = <DiagEvent>[];
      diagEventSink = events.add;
      final adapter = _FailingAdapter();
      final client = DeviceListService(
        webuiBaseUrl: "https://h.test",
        dio: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(client.list(), throwsA(isA<Object>()));

      expect(adapter.requests, isNotEmpty);
      expect(events, hasLength(1));
      expect(events.single.code, "net.request_failed");
      expect(events.single.fields["host"], "h.test");
      expect(events.single.fields["status"], 503);
    });
  });

  group("SKCapstoneClient", () {
    test("a failing request on the daemon Dio records one "
        "net.request_failed event", () async {
      final events = <DiagEvent>[];
      diagEventSink = events.add;
      final adapter = _FailingAdapter();
      final client = SKCapstoneClient(
        baseUrl: "http://skcapstone.test:7777",
        dio: Dio(BaseOptions(baseUrl: "http://skcapstone.test:7777"))
          ..httpClientAdapter = adapter,
      );

      final alive = await client.isAlive();

      expect(alive, isFalse);
      expect(adapter.requests, isNotEmpty);
      expect(events, hasLength(1));
      expect(events.single.code, "net.request_failed");
      expect(events.single.fields["host"], "skcapstone.test");
      expect(events.single.fields["status"], 503);
    });
  });

  group("PqPrekeyService", () {
    test("a failing request records one net.request_failed event", () async {
      final events = <DiagEvent>[];
      diagEventSink = events.add;
      final adapter = _FailingAdapter();
      final dio = Dio(BaseOptions(baseUrl: "http://localhost:9384"))
        ..httpClientAdapter = adapter;
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: "http://localhost:9384",
        deviceId: "dev-test",
        dio: dio,
      );

      await svc.fetchPeer("chef");

      expect(adapter.requests, isNotEmpty);
      expect(events, hasLength(1));
      expect(events.single.code, "net.request_failed");
      expect(events.single.fields["host"], "localhost");
      expect(events.single.fields["status"], 503);
    });
  });
}
