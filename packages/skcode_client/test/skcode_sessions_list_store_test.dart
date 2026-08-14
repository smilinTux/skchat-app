import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

class _FakeApiClient implements SkcodeApiClient {
  @override
  Future<SkcodeDigest> fetchDigest({required String token}) async {
    throw UnimplementedError("the digest route is not exercised by this file");
  }
  int calls = 0;
  final List<SkcodeSessionSummary> Function() onListSessions;
  _FakeApiClient(this.onListSessions);

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async {
    calls++;
    return onListSessions();
  }

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(String sid,
      {required String token, int? beforeSeq, int limit = 100}) async {
    throw UnimplementedError();
  }

  @override
  Future<List<SkcodeJobRun>> listJobs({required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsListStore tests");
  }

  @override
  Future<void> injectText(String sid, String text, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsListStore tests");
  }

  @override
  Future<void> ratifySession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsListStore tests");
  }

  @override
  Future<SkcodeDispatchTargets> fetchDispatchTargets({required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsListStore tests");
  }

  @override
  Future<SkcodeDispatchResult> dispatch({
    required String repo,
    required String branch,
    required String profile,
    required String permissionMode,
    required String mode,
    required String prompt,
    required String harness,
    required String model,
    required String token,
  }) async {
    throw UnimplementedError("not exercised by SkcodeSessionsListStore tests");
  }

  @override
  Future<SkcodeCancelResult> cancelSession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsListStore tests");
  }
}

void main() {
  test("startPolling fetches immediately, then every pollInterval", () async {
    var call = 0;
    final client = _FakeApiClient(() {
      call++;
      return [SkcodeSessionSummary(sid: "s$call")];
    });
    final store = SkcodeSessionsListStore(
      apiClient: client,
      mintToken: () async => "T",
      pollInterval: const Duration(milliseconds: 40),
    );

    final results = <SkcodeSessionsPoll>[];
    final sub = store.sessions.listen(results.add);

    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(results, hasLength(1), reason: "the first fetch fires immediately");
    expect(results.single.sessions.single.sid, "s1");
    expect(results.single.everSucceeded, isTrue);
    expect(results.single.failureKind, SkcodeSessionsFailureKind.none);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(results.length, greaterThanOrEqualTo(2),
        reason: "a second fetch must fire after pollInterval elapses");

    await sub.cancel();
    await store.dispose();
  });

  test("stopPolling stops further fetches", () async {
    final client = _FakeApiClient(() => const []);
    final store = SkcodeSessionsListStore(
      apiClient: client,
      mintToken: () async => "T",
      pollInterval: const Duration(milliseconds: 30),
    );

    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(client.calls, 1);

    store.stopPolling();
    final callsAtStop = client.calls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(client.calls, callsAtStop, reason: "no further polling after stop");

    await store.dispose();
  });

  test("startPolling twice in a row is a no-op (does not double the timer)",
      () async {
    final client = _FakeApiClient(() => const []);
    final store = SkcodeSessionsListStore(
      apiClient: client,
      mintToken: () async => "T",
      pollInterval: const Duration(milliseconds: 200),
    );

    store.startPolling();
    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(client.calls, 1, reason: "the immediate fetch must not double-fire");

    await store.dispose();
  });

  group("card C-19: honest failure states", () {
    test(
        "no token available: the HTTP call is skipped, and the poll reports "
        "unauthorized (never minted is the same operator message as rejected)",
        () async {
      var listCalls = 0;
      final client = _FakeApiClient(() {
        listCalls++;
        return const [];
      });
      final store = SkcodeSessionsListStore(
        apiClient: client,
        mintToken: () async => null,
        pollInterval: const Duration(milliseconds: 200),
      );

      final results = <SkcodeSessionsPoll>[];
      final sub = store.sessions.listen(results.add);

      store.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(listCalls, 0, reason: "no token means no API call at all");

      expect(results, hasLength(1));
      expect(results.single.everSucceeded, isFalse);
      expect(results.single.failureKind, SkcodeSessionsFailureKind.unauthorized);
      expect(results.single.sessions, isEmpty);

      await sub.cancel();
      await store.dispose();
    });

    test(
        "a 401 from skcode-hostd (SkcodeUnauthorizedException) reports "
        "unauthorized, the same as a never-minted token", () async {
      final client = _FakeApiClient(() {
        throw const SkcodeUnauthorizedException("token rejected");
      });
      final store = SkcodeSessionsListStore(
        apiClient: client,
        mintToken: () async => "T",
        pollInterval: const Duration(milliseconds: 200),
      );

      final results = <SkcodeSessionsPoll>[];
      final sub = store.sessions.listen(results.add);

      store.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(results, hasLength(1));
      expect(results.single.everSucceeded, isFalse);
      expect(results.single.failureKind, SkcodeSessionsFailureKind.unauthorized);
      expect(results.single.sessions, isEmpty);

      await sub.cancel();
      await store.dispose();
    });

    test(
        "any other failure (transport/DNS/timeout/non-401 HTTP) reports "
        "unreachable, distinct from unauthorized", () async {
      final client = _FakeApiClient(() {
        throw const SkcodeApiException("connection refused");
      });
      final store = SkcodeSessionsListStore(
        apiClient: client,
        mintToken: () async => "T",
        pollInterval: const Duration(milliseconds: 200),
      );

      final results = <SkcodeSessionsPoll>[];
      final sub = store.sessions.listen(results.add);

      store.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(results, hasLength(1));
      expect(results.single.everSucceeded, isFalse);
      expect(results.single.failureKind, SkcodeSessionsFailureKind.unreachable);
      expect(results.single.sessions, isEmpty);

      await sub.cancel();
      await store.dispose();
    });

    test(
        "a successful poll with zero rows is a distinct 'empty' outcome, "
        "not folded into either failure kind", () async {
      final client = _FakeApiClient(() => const []);
      final store = SkcodeSessionsListStore(
        apiClient: client,
        mintToken: () async => "T",
        pollInterval: const Duration(milliseconds: 200),
      );

      final results = <SkcodeSessionsPoll>[];
      final sub = store.sessions.listen(results.add);

      store.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(results, hasLength(1));
      expect(results.single.everSucceeded, isTrue);
      expect(results.single.failureKind, SkcodeSessionsFailureKind.none);
      expect(results.single.sessions, isEmpty);

      await sub.cancel();
      await store.dispose();
    });

    test(
        "a transient failure AFTER a prior success keeps the last known "
        "good list (does not blank it), while still reporting the failure "
        "kind of the most recent attempt", () async {
      var call = 0;
      final client = _FakeApiClient(() {
        call++;
        if (call == 1) return [const SkcodeSessionSummary(sid: "s-good")];
        throw const SkcodeApiException("blip");
      });
      final store = SkcodeSessionsListStore(
        apiClient: client,
        mintToken: () async => "T",
        pollInterval: const Duration(milliseconds: 30),
      );

      final results = <SkcodeSessionsPoll>[];
      final sub = store.sessions.listen(results.add);

      store.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(results.length, greaterThanOrEqualTo(2));
      final first = results.first;
      expect(first.everSucceeded, isTrue);
      expect(first.sessions.single.sid, "s-good");

      final last = results.last;
      expect(last.everSucceeded, isTrue,
          reason: "a prior success stays true forever, even after a later failure");
      expect(last.failureKind, SkcodeSessionsFailureKind.unreachable);
      expect(last.sessions.single.sid, "s-good",
          reason: "the last known-good list must survive a transient failure, "
              "never blanking to empty");

      await sub.cancel();
      await store.dispose();
    });

    test(
        "an unauthorized failure AFTER a prior success also keeps the last "
        "known good list (a mid-session token expiry is still transient)",
        () async {
      var call = 0;
      final client = _FakeApiClient(() {
        call++;
        if (call == 1) return [const SkcodeSessionSummary(sid: "s-good")];
        throw const SkcodeUnauthorizedException("expired");
      });
      final store = SkcodeSessionsListStore(
        apiClient: client,
        mintToken: () async => "T",
        pollInterval: const Duration(milliseconds: 30),
      );

      final results = <SkcodeSessionsPoll>[];
      final sub = store.sessions.listen(results.add);

      store.startPolling();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final last = results.last;
      expect(last.everSucceeded, isTrue);
      expect(last.failureKind, SkcodeSessionsFailureKind.unauthorized);
      expect(last.sessions.single.sid, "s-good");

      await sub.cancel();
      await store.dispose();
    });
  });

  test("a transient fetch failure does not crash and the next poll still fires",
      () async {
    var call = 0;
    final client = _FakeApiClient(() {
      call++;
      if (call == 1) throw Exception("transient");
      return [SkcodeSessionSummary(sid: "recovered")];
    });
    final store = SkcodeSessionsListStore(
      apiClient: client,
      mintToken: () async => "T",
      pollInterval: const Duration(milliseconds: 30),
    );

    final results = <SkcodeSessionsPoll>[];
    final sub = store.sessions.listen(results.add);

    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(results, isNotEmpty);
    expect(results.last.sessions.single.sid, "recovered");
    expect(results.last.everSucceeded, isTrue);
    expect(results.last.failureKind, SkcodeSessionsFailureKind.none);

    await sub.cancel();
    await store.dispose();
  });
}
