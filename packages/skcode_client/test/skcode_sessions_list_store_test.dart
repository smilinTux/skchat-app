import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

class _FakeApiClient implements SkcodeApiClient {
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

    final results = <List<SkcodeSessionSummary>>[];
    final sub = store.sessions.listen(results.add);

    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(results, hasLength(1), reason: "the first fetch fires immediately");
    expect(results.single.single.sid, "s1");

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

  test("no token available: the poll is skipped, not an error", () async {
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

    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(listCalls, 0, reason: "no token means no API call at all");

    await store.dispose();
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

    final results = <List<SkcodeSessionSummary>>[];
    final sub = store.sessions.listen(results.add);

    store.startPolling();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(results, isNotEmpty);
    expect(results.last.single.sid, "recovered");

    await sub.cancel();
    await store.dispose();
  });
}
