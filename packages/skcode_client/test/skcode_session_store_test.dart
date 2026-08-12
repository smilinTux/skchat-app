import "dart:async";
import "dart:convert";
import "dart:math";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// A controllable [SkcodeWsTransport]: tests push frames via [emit] and end
/// the connection via [simulateClose], standing in for the daemon
/// dying/restarting or the server closing 1008 on a bad token.
class _FakeWsTransport implements SkcodeWsTransport {
  _FakeWsTransport({this.readyError});

  final Object? readyError;
  final _streamController = StreamController<dynamic>.broadcast();
  int? _closeCode;
  bool closeCalled = false;

  @override
  Future<void> get ready async {
    if (readyError != null) throw readyError!;
  }

  @override
  Stream<dynamic> get stream => _streamController.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  Future<void> close() async {
    closeCalled = true;
    if (!_streamController.isClosed) await _streamController.close();
  }

  void emit(Map<String, dynamic> frame) {
    _streamController.add(jsonEncode(frame));
  }

  /// Simulate the server (or the pipe) closing with [code]. `null` models an
  /// abrupt drop (e.g. the daemon process was killed) with no close frame.
  void simulateClose(int? code) {
    _closeCode = code;
    if (!_streamController.isClosed) unawaited(_streamController.close());
  }
}

/// Scripts a sequence of HTTP responses for `SkcodeApiClient`'s underlying
/// Dio, one per request received (in order), matching the project's existing
/// canned-adapter test style.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._script);

  final List<({int status, Object body})> _script;
  final List<RequestOptions> requests = [];
  int _i = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final entry = _i < _script.length ? _script[_i] : _script.last;
    _i++;
    return ResponseBody.fromString(
      jsonEncode(entry.body),
      entry.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

Map<String, dynamic> _eventJson({
  required String sid,
  required int seq,
  required double ts,
  String type = "assistant_text",
  String text = "",
}) => {"type": type, "text": text, "ts": ts, "data": <String, dynamic>{}, "seq": seq, "sid": sid, "source": "interactive"};

/// Wires a [SkcodeSessionStore] against fakes.
///
/// [tokens] models the REAL `AudienceTokenService` contract, not a plain
/// call-counter: `mintToken()` returns the CURRENT cached value on every
/// call (any number of calls in a row see the same token, exactly like a
/// production cache hit), and only `onAuthRejected()` advances to the next
/// scripted value (a production cache miss/re-mint). This matters because
/// the store calls `mintToken()` more than once per connect cycle (once for
/// the archive fetch, once for the WS URL) - in production that is a cheap
/// cache hit, not a second network round-trip, so the test double must
/// behave the same way or its token-sequence assertions would drift from
/// what actually happens on the wire.
///
/// [onAuthRejectedCalls] counts every `onAuthRejected()` invocation directly
/// (card C-3b AC: "proven by a test that the callback fires"), independent
/// of the token-sequence/reconnect assertions the rest of this file already
/// makes.
({
  SkcodeSessionStore store,
  List<_FakeWsTransport> transports,
  List<Uri> connectedUris,
  List<String?> mintedTokens,
  List<int> onAuthRejectedCalls,
})
_wire({
  required List<String?> tokens,
  List<({int status, Object body})> archiveScript = const [
    (status: 200, body: {"sid": "s1", "events": <Map<String, dynamic>>[]}),
  ],
  Duration Function(int attempt)? backoffFor,
  int maxLiveEvents = kMaxLiveSkcodeEvents,
}) {
  var cursor = 0;
  final mintedTokens = <String?>[];
  final transports = <_FakeWsTransport>[];
  final connectedUris = <Uri>[];
  final onAuthRejectedCalls = <int>[];

  final adapter = _ScriptedAdapter(archiveScript);
  final dio = Dio(BaseOptions(baseUrl: "https://daemon.local"))
    ..httpClientAdapter = adapter;
  final apiClient = SkcodeApiClient(dio: dio);

  final store = SkcodeSessionStore(
    sid: "s1",
    apiClient: apiClient,
    mintToken: () async {
      final t = tokens.isEmpty ? null : tokens[cursor.clamp(0, tokens.length - 1)];
      mintedTokens.add(t);
      return t;
    },
    onAuthRejected: () {
      onAuthRejectedCalls.add(onAuthRejectedCalls.length + 1);
      if (cursor < tokens.length - 1) cursor++;
    },
    connectTransport: (uri) {
      connectedUris.add(uri);
      final t = _FakeWsTransport();
      transports.add(t);
      return t;
    },
    buildWsUri: (sid, token) =>
        Uri.parse("wss://daemon.local/skcode/api/v1/sessions/$sid/stream?token=$token"),
    backoffFor: backoffFor ?? (attempt) => Duration.zero,
    maxLiveEvents: maxLiveEvents,
  );

  return (
    store: store,
    transports: transports,
    connectedUris: connectedUris,
    mintedTokens: mintedTokens,
    onAuthRejectedCalls: onAuthRejectedCalls,
  );
}

void main() {
  group("WS auth: token in the query string, exactly once", () {
    test("connects with ?token=<wire> (never a header, WS cannot set one)",
        () async {
      final w = _wire(tokens: ["TOK-1"]);
      await w.store.start();
      await pumpEventQueue();

      expect(w.connectedUris.single.queryParameters["token"], "TOK-1");
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);
      await w.store.dispose();
    });
  });

  group("WS 1008: exactly one re-mint + retry, then fail visibly (no loop)", () {
    test("a 1008 close re-mints once and the retry succeeds", () async {
      final w = _wire(tokens: ["STALE", "FRESH"]);
      await w.store.start();
      await pumpEventQueue();

      expect(w.transports, hasLength(1));
      w.transports[0].simulateClose(1008);
      await pumpEventQueue();

      // Exactly one re-mint, exactly one retry connect (2 total).
      expect(w.transports, hasLength(2), reason: "exactly one retry connect");
      expect(w.connectedUris[1].queryParameters["token"], "FRESH");
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);
      // Card C-3b AC: "proven by a test that the callback fires" - the
      // injected onAuthRejected callback itself (not just its downstream
      // effect on the token/reconnect sequence) fired exactly once.
      expect(w.onAuthRejectedCalls, hasLength(1),
          reason: "onAuthRejected must fire exactly once per 1008");
      await w.store.dispose();
    });

    test("a SECOND 1008 in the same cycle fails visibly instead of looping",
        () async {
      final w = _wire(tokens: ["STALE", "STILL-BAD"]);
      await w.store.start();
      await pumpEventQueue();

      w.transports[0].simulateClose(1008);
      await pumpEventQueue();
      // The retry (transport #2) is ALSO rejected.
      w.transports[1].simulateClose(1008);
      await pumpEventQueue();

      expect(
        w.transports,
        hasLength(2),
        reason: "no third connect attempt: re-mint happens once per cycle, not in a loop",
      );
      expect(w.store.state.phase, SkcodeConnectionPhase.failed);
      expect(w.store.state.error, contains("1008"));
      expect(w.onAuthRejectedCalls, hasLength(1),
          reason: "onAuthRejected fires once per cycle, never a second time "
              "for the same cycle's repeat 1008");
      await w.store.dispose();
    });

    test("a fully NEW reconnect cycle (a later, unrelated disconnect) gets its "
        "own fresh re-mint budget, so one old 1008 never permanently wedges "
        "a long-lived session", () async {
      final w = _wire(tokens: ["A", "B", "C"]);
      await w.store.start();
      await pumpEventQueue();
      expect(w.connectedUris[0].queryParameters["token"], "A");

      // Incident 1: 1008 -> re-mint -> retry succeeds (token B). The budget
      // stays SPENT for as long as this is the same incident.
      w.transports[0].simulateClose(1008);
      await pumpEventQueue();
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);
      expect(w.transports, hasLength(2));
      expect(w.connectedUris[1].queryParameters["token"], "B");

      // Time passes; the session runs fine, then drops for an ORDINARY,
      // unrelated reason (network blip / daemon restart) -- NOT a 1008. This
      // is what starts a genuinely new cycle. The token is NOT invalidated by
      // an ordinary disconnect (no auth problem happened), so the reconnect
      // legitimately reuses the still-cached token B — exactly like
      // production, where `AudienceTokenService.mint()` keeps serving the
      // cache until something actually invalidates it.
      w.transports[1].simulateClose(1006);
      await pumpEventQueue();
      expect(w.transports, hasLength(3));
      expect(w.connectedUris[2].queryParameters["token"], "B");
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);

      // NOW a fresh, independent 1008 on this NEW cycle (e.g. the operator
      // revoked access again) gets its own single re-mint retry (-> C), not
      // an immediate fail — proving the earlier incident did not
      // permanently spend the budget.
      w.transports[2].simulateClose(1008);
      await pumpEventQueue();

      expect(w.transports, hasLength(4));
      expect(w.connectedUris[3].queryParameters["token"], "C");
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);
      await w.store.dispose();
    });
  });

  group("EXIT TEST: kill the daemon mid-stream, reconnect is honest, no duplicates",
      () {
    test("a non-1008 close reconnects with backoff, re-fetches the archive, "
        "and the merge across the seq reset loses nothing and dedups nothing "
        "it should not", () async {
      const sid = "s1";
      // The archive fetch is scripted to run TWICE: once at start() (empty,
      // nothing archived yet) and once on reconnect (now holding the 3
      // pre-restart events the store received live before the kill, exactly
      // as skharness's SessionEventStore would have on a real restart: the
      // JSONL archive keeps what was appended before the process died).
      final w = _wire(
        tokens: ["T1", "T1", "T1"],
        archiveScript: [
          (status: 200, body: {"sid": sid, "events": <Map<String, dynamic>>[]}),
          (
            status: 200,
            body: {
              "sid": sid,
              "events": [
                _eventJson(sid: sid, seq: 1, ts: 1000.0, text: "before-1"),
                _eventJson(sid: sid, seq: 2, ts: 1001.0, text: "before-2"),
                _eventJson(sid: sid, seq: 3, ts: 1002.0, text: "before-3"),
              ],
            },
          ),
        ],
      );

      await w.store.start();
      await pumpEventQueue();
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);
      expect(w.store.state.events, isEmpty);

      // "kill the daemon mid-stream": the socket drops with no close frame,
      // never 1008 (this is NOT an auth failure).
      w.transports[0].simulateClose(null);
      await pumpEventQueue();

      // Honest reconnect: a NEW connect attempt happened (not a silent
      // no-op), and the phase moved through reconnecting.
      expect(w.transports, hasLength(2),
          reason: "the daemon death must trigger a real second connect attempt");
      expect(w.store.state.phase, SkcodeConnectionPhase.connected);
      expect(w.store.reconnectAttempts, 0,
          reason: "attempt counter resets to 0 after a successful reconnect");

      // The reconnect's archive re-fetch merged in the 3 pre-restart events.
      expect(w.store.state.events.map((e) => e.text).toList(),
          ["before-1", "before-2", "before-3"]);

      // The NEW daemon process's session buffer is fresh: seq restarts at 1,
      // but ts keeps climbing. Feed 3 "post-restart" live frames with the
      // SAME seq numbers as the archived pre-restart ones.
      w.transports[1].emit(_eventJson(sid: sid, seq: 1, ts: 5000.0, text: "after-1"));
      w.transports[1].emit(_eventJson(sid: sid, seq: 2, ts: 5001.0, text: "after-2"));
      w.transports[1].emit(_eventJson(sid: sid, seq: 3, ts: 5002.0, text: "after-3"));
      await pumpEventQueue();

      final texts = w.store.state.events.map((e) => e.text).toList();
      expect(
        texts,
        ["before-1", "before-2", "before-3", "after-1", "after-2", "after-3"],
        reason: "all 6 rows must be present in ascending (ts, seq) order; a "
            "(sid, seq)-only dedup key would have collapsed this to 3",
      );
      expect(w.store.state.events.toSet().length, w.store.state.events.length,
          reason: "no duplicate rows");

      await w.store.dispose();
    });

    test("reconnect uses the injected backoff schedule, not an immediate retry",
        () async {
      final delays = <int>[];
      final w = _wire(
        tokens: ["T1"],
        backoffFor: (attempt) {
          delays.add(attempt);
          return const Duration(milliseconds: 80);
        },
      );

      await w.store.start();
      await pumpEventQueue();
      expect(w.transports, hasLength(1));

      w.transports[0].simulateClose(1006); // abnormal closure, not 1008
      await pumpEventQueue();

      // Not reconnected yet: pumpEventQueue only flushes microtasks/
      // zero-delay macrotasks, never an 80ms real Timer.
      expect(w.transports, hasLength(1));
      expect(w.store.state.phase, SkcodeConnectionPhase.reconnecting);

      // Real wall-clock wait, comfortably longer than the scheduled delay.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(w.transports, hasLength(2), reason: "reconnected once the delay elapsed");
      expect(delays, [1]);

      await w.store.dispose();
    });
  });

  group("live window cap (3000, Buzz's MAX_OBSERVER_EVENTS)", () {
    test("live events beyond the cap are trimmed, oldest first", () async {
      final w = _wire(tokens: ["T"], maxLiveEvents: 5);
      await w.store.start();
      await pumpEventQueue();

      for (var i = 0; i < 8; i++) {
        w.transports[0].emit(_eventJson(sid: "s1", seq: i, ts: i.toDouble()));
      }
      await pumpEventQueue();

      expect(w.store.state.events, hasLength(5));
      expect(w.store.state.events.first.seq, 3);
      expect(w.store.state.events.last.seq, 7);
      await w.store.dispose();
    });

    test("archive paging extends the merged view beyond the live cap", () async {
      final archiveEvents = List.generate(
        10,
        (i) => _eventJson(sid: "s1", seq: 100 + i, ts: 100.0 + i),
      );
      final w = _wire(
        tokens: ["T"],
        maxLiveEvents: 5,
        archiveScript: [
          (status: 200, body: {"sid": "s1", "events": archiveEvents}),
        ],
      );
      await w.store.start();
      await pumpEventQueue();

      for (var i = 0; i < 8; i++) {
        w.transports[0].emit(_eventJson(sid: "s1", seq: i, ts: 1000.0 + i));
      }
      await pumpEventQueue();

      // 10 archived + 5 (capped live) = 15, NOT capped down to 5: the
      // archive is never truncated by the live-window cap (spec 5.3/AC5).
      expect(w.store.state.events, hasLength(15));
      await w.store.dispose();
    });
  });

  group("connect failure (handshake never completes)", () {
    test("a ready() error is treated like a drop: schedules a reconnect, not a crash",
        () async {
      var tokenCalls = 0;
      var connectCalls = 0;
      SkcodeWsTransport factory(Uri uri) {
        connectCalls++;
        return connectCalls == 1
            ? _FakeWsTransport(readyError: Exception("handshake refused"))
            : _FakeWsTransport();
      }

      final adapter = _ScriptedAdapter(const [
        (status: 200, body: {"sid": "s1", "events": <Map<String, dynamic>>[]}),
      ]);
      final dio = Dio(BaseOptions(baseUrl: "https://daemon.local"))
        ..httpClientAdapter = adapter;
      final store = SkcodeSessionStore(
        sid: "s1",
        apiClient: SkcodeApiClient(dio: dio),
        mintToken: () async {
          tokenCalls++;
          return "T";
        },
        onAuthRejected: () {},
        connectTransport: factory,
        buildWsUri: (sid, token) => Uri.parse("wss://daemon.local/x?token=$token"),
        backoffFor: (attempt) => const Duration(milliseconds: 80),
      );

      await store.start();
      await pumpEventQueue();

      expect(connectCalls, 1);
      expect(store.state.phase, SkcodeConnectionPhase.reconnecting);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(connectCalls, 2, reason: "a failed handshake must still retry");
      expect(store.state.phase, SkcodeConnectionPhase.connected);
      expect(tokenCalls, greaterThanOrEqualTo(2),
          reason: "a fresh mint happens on the retry too");

      await store.dispose();
    });
  });

  group("no audience token available", () {
    test("start() surfaces failed with no phantom connect attempt", () async {
      final w = _wire(tokens: [null]);
      await w.store.start();
      await pumpEventQueue();

      expect(w.store.state.phase, SkcodeConnectionPhase.failed);
      expect(w.transports, isEmpty);
      await w.store.dispose();
    });
  });

  group("defaultSkcodeBackoff", () {
    test("stays within [base, max*1.3] jitter bounds for every attempt",
        () {
      const base = Duration(milliseconds: 500);
      const max = Duration(seconds: 30);
      for (var attempt = 1; attempt <= 10; attempt++) {
        final d = defaultSkcodeBackoff(attempt, base: base, max: max);
        expect(d, greaterThanOrEqualTo(base));
        expect(d.inMilliseconds, lessThanOrEqualTo((max.inMilliseconds * 1.31).round()));
      }
    });

    test("the pre-jitter floor grows with attempt (a fixed random source "
        "isolates the exponential curve from jitter noise)", () {
      const base = Duration(milliseconds: 500);
      const max = Duration(seconds: 30);
      // Random(0) always returns the SAME sequence of nextDouble() values in
      // the Dart VM, so two calls at the same attempt are reproducible; what
      // varies attempt-to-attempt is purely the exponential floor.
      final d1 = defaultSkcodeBackoff(1, base: base, max: max, random: Random(0));
      final d3 = defaultSkcodeBackoff(3, base: base, max: max, random: Random(0));
      final d6 = defaultSkcodeBackoff(6, base: base, max: max, random: Random(0));
      expect(d3.inMilliseconds, greaterThan(d1.inMilliseconds));
      expect(d6.inMilliseconds, greaterThan(d3.inMilliseconds));
    });

    test("saturates at max for large attempts (never grows unbounded)", () {
      final d = defaultSkcodeBackoff(50, max: const Duration(seconds: 30));
      expect(d.inMilliseconds, lessThanOrEqualTo((30000 * 1.31).round()));
    });
  });
}
