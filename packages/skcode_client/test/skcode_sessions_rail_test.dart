import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";
import "package:skworld_module_api/skworld_module_api.dart";

/// A [SkcodeWsTransport] whose `ready` never resolves, so a pushed
/// [SkcodeSessionScreen] never opens (or waits on) a real socket in a
/// widget test. Mirrors the fakes in `skcode_session_store_test.dart`.
class _FakeWsTransport implements SkcodeWsTransport {
  final _streamController = StreamController<dynamic>.broadcast();

  @override
  Future<void> get ready => Completer<void>().future; // never completes.
  @override
  Stream<dynamic> get stream => _streamController.stream;
  @override
  int? get closeCode => null;
  @override
  Future<void> close() async {
    if (!_streamController.isClosed) await _streamController.close();
  }
}

class _FakeApiClient implements SkcodeApiClient {
  @override
  Future<SkcodeDigest> fetchDigest({required String token}) async {
    throw UnimplementedError("the digest route is not exercised by this file");
  }
  _FakeApiClient({
    this.sessions = const [],
    this.jobs = const [],
    this.jobsError,
    this.sessionsError,
  });

  final List<SkcodeSessionSummary> sessions;

  /// Rows [listJobs] resolves with, unless [jobsError] is set.
  final List<SkcodeJobRun> jobs;

  /// When set, [listJobs] throws this instead of returning [jobs] (the
  /// "endpoint unavailable" degrade-state test seam).
  final Object? jobsError;

  /// When set, [listSessions] throws this instead of returning [sessions]
  /// (card C-19's unauthorized/unreachable degrade-state test seam).
  final Object? sessionsError;

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async {
    final err = sessionsError;
    if (err != null) throw err;
    return sessions;
  }

  @override
  Future<List<SkcodeJobRun>> listJobs({required String token}) async {
    final err = jobsError;
    if (err != null) throw err;
    return jobs;
  }

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async =>
      const [];

  @override
  Future<void> injectText(String sid, String text, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsRail tests");
  }

  @override
  Future<void> ratifySession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsRail tests");
  }

  @override
  Future<SkcodeDispatchTargets> fetchDispatchTargets({required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsRail tests");
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
    throw UnimplementedError("not exercised by SkcodeSessionsRail tests");
  }

  @override
  Future<SkcodeCancelResult> cancelSession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionsRail tests");
  }
}

void main() {
  testWidgets("renders a tile per session from the poll", (tester) async {
    final apiClient = _FakeApiClient(
      sessions: const [
        SkcodeSessionSummary(sid: "s-1", harness: "claude-code", state: "running"),
        SkcodeSessionSummary(sid: "s-2", harness: "claude-code", state: "idle"),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeSessionsRail(
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text("s-1"), findsOneWidget);
    expect(find.text("s-2"), findsOneWidget);
  });

  testWidgets("renders the empty state with no sessions", (tester) async {
    final apiClient = _FakeApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SkcodeSessionsRail(
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key("skcodeSessionsEmpty")), findsOneWidget);
    expect(find.text("No active sessions"), findsOneWidget);
  });

  group("card C-19: honest sessions failure states (not folded into 'No sessions yet')", () {
    testWidgets(
        "a null token (never minted) renders 'No access yet', not the empty state",
        (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => null,
              onAuthRejected: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeSessionsUnauthorized")), findsOneWidget);
      expect(find.text("No access yet"), findsOneWidget);
      expect(find.byKey(const Key("skcodeSessionsEmpty")), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        "a 401 (SkcodeUnauthorizedException) renders 'No access yet', the same "
        "state as a never-minted token", (tester) async {
      final apiClient = _FakeApiClient(
        sessionsError: const SkcodeUnauthorizedException("rejected"),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeSessionsUnauthorized")), findsOneWidget);
      expect(find.text("No access yet"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        "a network/transport failure renders 'Could not reach host', distinct "
        "from the unauthorized state", (tester) async {
      final apiClient = _FakeApiClient(
        sessionsError: const SkcodeApiException("connection refused"),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeSessionsUnreachable")), findsOneWidget);
      expect(find.text("Could not reach host"), findsOneWidget);
      expect(find.byKey(const Key("skcodeSessionsUnauthorized")), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // The transient-failure-after-success behavior (a later failed poll must
    // never blank an already-populated list, regardless of which failure
    // kind it is) is exercised at the store level in
    // skcode_sessions_list_store_test.dart, where a short pollInterval can
    // drive multiple real poll cycles without adding a pollInterval knob to
    // this widget's public API just for test timing. SkcodeSessionsRail
    // itself adds nothing on top of SkcodeSessionsPoll.sessions/everSucceeded
    // beyond the render branch asserted above (everSucceeded == false is the
    // only condition that swaps the list for a failure state).
  });

  testWidgets(
    "tapping a session row pushes the full-screen session view (spec section 7: "
    "'/code/s/:sid opens full screen')",
    (tester) async {
      final apiClient = _FakeApiClient(
        sessions: const [SkcodeSessionSummary(sid: "s-target")],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              // Never opens a real socket: `ready` never resolves.
              connectTransport: (_) => _FakeWsTransport(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeSessionScreen), findsNothing);

      await tester.tap(find.text("s-target"));
      // Explicit pumps (never pumpAndSettle): SkcodeSessionsListStore's
      // 15s poll Timer.periodic is still alive on the popped-from rail,
      // which would make pumpAndSettle wait needlessly.
      await tester.pump(); // frame that starts the push transition.
      await tester.pump(const Duration(milliseconds: 400)); // transition settles.

      expect(find.byType(SkcodeSessionScreen), findsOneWidget);
      // The AppBar of the pushed screen names the session id.
      expect(find.widgetWithText(AppBar, "s-target"), findsOneWidget);
    },
  );

  testWidgets(
    "forwards auth and the tapped session's mode==interactive through to "
    "the pushed SkcodeSessionScreen (card C-5's gate, AC4)",
    (tester) async {
      const auth = _FakeAuth(scopes: {"skcode.inject"});
      final apiClient = _FakeApiClient(
        sessions: const [SkcodeSessionSummary(sid: "s-interactive", mode: "interactive")],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              connectTransport: (_) => _FakeWsTransport(),
              auth: auth,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text("s-interactive"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The composer only renders when the pushed screen actually received
      // BOTH the scope-carrying auth and interactive: true.
      expect(find.byType(SkcodeInjectComposer), findsOneWidget);
    },
  );

  group("Jobs section (card C-8, spec section 8)", () {
    testWidgets(
      "renders a Jobs section beneath Sessions with name, last-run and status",
      (tester) async {
        final apiClient = _FakeApiClient(
          sessions: const [SkcodeSessionSummary(sid: "s-1")],
          jobs: const [
            SkcodeJobRun(
              job: "drchiro-ingest",
              host: "noroc2027",
              status: "ok",
              stale: false,
              stalenessS: 120,
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SkcodeSessionsRail(
                apiClient: apiClient,
                origin: "http://localhost:9384",
                mintToken: () async => "T",
                onAuthRejected: () {},
              ),
            ),
          ),
        );
        await tester.pump();

        // Sessions still render (the Jobs section is ADDITIVE, beneath).
        expect(find.text("s-1"), findsOneWidget);
        expect(find.text("Jobs"), findsOneWidget);
        expect(find.text("drchiro-ingest"), findsOneWidget);
        expect(find.textContaining("noroc2027"), findsOneWidget);
        expect(find.textContaining("OK"), findsOneWidget);
      },
    );

    testWidgets(
      "a stale job's staleness badge renders distinctly from a healthy job's",
      (tester) async {
        final apiClient = _FakeApiClient(
          jobs: const [
            SkcodeJobRun(job: "fresh-job", status: "ok", stale: false, stalenessS: 30),
            SkcodeJobRun(job: "stale-job", status: "ok", stale: true, stalenessS: 999999),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SkcodeSessionsRail(
                apiClient: apiClient,
                origin: "http://localhost:9384",
                mintToken: () async => "T",
                onAuthRejected: () {},
              ),
            ),
          ),
        );
        await tester.pump();

        // Distinct keys, distinct labels.
        expect(find.byKey(const Key("skcodeJobBadgeFresh")), findsOneWidget);
        expect(find.byKey(const Key("skcodeJobBadgeStale")), findsOneWidget);
        expect(find.text("FRESH"), findsOneWidget);
        expect(find.text("STALE"), findsOneWidget);

        // And distinct color, not merely distinct text: the badge must read
        // "visually obvious at a glance" (card C-8), not just on close read.
        final freshBadge = tester.widget<Container>(
          find.byKey(const Key("skcodeJobBadgeFresh")),
        );
        final staleBadge = tester.widget<Container>(
          find.byKey(const Key("skcodeJobBadgeStale")),
        );
        final freshColor = (freshBadge.decoration as BoxDecoration).color;
        final staleColor = (staleBadge.decoration as BoxDecoration).color;
        expect(freshColor, isNot(equals(staleColor)));
      },
    );

    testWidgets(
      "a job with status unknown renders a clear Unknown state, not a crash",
      (tester) async {
        final apiClient = _FakeApiClient(
          jobs: const [SkcodeJobRun(job: "mystery-job", status: "unknown", stale: true)],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SkcodeSessionsRail(
                apiClient: apiClient,
                origin: "http://localhost:9384",
                mintToken: () async => "T",
                onAuthRejected: () {},
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text("mystery-job"), findsOneWidget);
        expect(find.textContaining("Unknown"), findsOneWidget);
        // "unknown" carries no known-good timestamp, so the badge still
        // reads stale rather than silently defaulting to fresh.
        expect(find.byKey(const Key("skcodeJobBadgeStale")), findsOneWidget);
      },
    );

    testWidgets(
      "an empty job list renders a clear empty state, not a blank area",
      (tester) async {
        final apiClient = _FakeApiClient(jobs: const []);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SkcodeSessionsRail(
                apiClient: apiClient,
                origin: "http://localhost:9384",
                mintToken: () async => "T",
                onAuthRejected: () {},
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text("No scheduled jobs"), findsOneWidget);
      },
    );

    testWidgets(
      "the jobs endpoint being unavailable renders a clear state, not a crash",
      (tester) async {
        final apiClient = _FakeApiClient(
          jobsError: const SkcodeApiException("boom"),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SkcodeSessionsRail(
                apiClient: apiClient,
                origin: "http://localhost:9384",
                mintToken: () async => "T",
                onAuthRejected: () {},
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text("Jobs unavailable"), findsOneWidget);
      },
    );

    testWidgets(
      "the Jobs section has no run-now/retry/cancel control and a row "
      "never navigates anywhere (view-only, card C-8: no mutating action)",
      (tester) async {
        final apiClient = _FakeApiClient(
          jobs: const [SkcodeJobRun(job: "job-1", status: "ok", stale: false)],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SkcodeSessionsRail(
                apiClient: apiClient,
                origin: "http://localhost:9384",
                mintToken: () async => "T",
                onAuthRejected: () {},
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(IconButton), findsNothing);
        expect(find.byType(ElevatedButton), findsNothing);
        expect(find.byType(FilledButton), findsNothing);
        expect(find.byType(TextButton), findsNothing);

        await tester.tap(find.text("job-1"));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(SkcodeSessionScreen), findsNothing);
      },
    );
  });

  group("card C-6: New Session entry point (spec section 8's \"New run\" row)", () {
    testWidgets("no New Session button without skcode.dispatch scope", (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              auth: const _FakeAuth(scopes: {"skcode.inject"}),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeNewSessionButton")), findsNothing);
    });

    testWidgets("no New Session button with no AuthContext at all (standalone, fails closed)",
        (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              // auth omitted entirely.
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeNewSessionButton")), findsNothing);
    });

    testWidgets("New Session button renders with skcode.dispatch scope", (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              auth: const _FakeAuth(scopes: {"skcode.dispatch"}),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeNewSessionButton")), findsOneWidget);
    });

    testWidgets("tapping New Session pushes SkcodeDispatchScreen, forwarding auth",
        (tester) async {
      final apiClient = _FakeApiClient();
      const auth = _FakeAuth(scopes: {"skcode.dispatch"});

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              auth: auth,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeDispatchScreen), findsNothing);

      await tester.tap(find.byKey(const Key("skcodeNewSessionButton")));
      // Explicit pumps (never pumpAndSettle): SkcodeSessionsListStore's
      // 15s poll Timer.periodic is still alive on the rail underneath, same
      // reason the "tapping a session row" test above avoids it.
      await tester.pump(); // frame that starts the push transition.
      await tester.pump(const Duration(milliseconds: 400)); // transition settles.

      expect(find.byType(SkcodeDispatchScreen), findsOneWidget);
      final screen = tester.widget<SkcodeDispatchScreen>(find.byType(SkcodeDispatchScreen));
      expect(screen.auth, same(auth));
    });
  });

  group("card C-12: inline selection, header chip, chat forwarding", () {
    testWidgets(
        "with onSessionSelected supplied, tapping a row calls it INSTEAD of pushing "
        "SkcodeSessionScreen (the wide-tier layout's inline-selection contract)",
        (tester) async {
      final apiClient = _FakeApiClient(
        sessions: const [SkcodeSessionSummary(sid: "s-1", repo: "skworld-app")],
      );
      SkcodeSessionSummary? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              onSessionSelected: (s) => selected = s,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text("s-1"));
      await tester.pump();

      expect(selected?.sid, "s-1");
      expect(find.byType(SkcodeSessionScreen), findsNothing);
    });

    testWidgets("without onSessionSelected, tapping a row still pushes (unchanged phone behavior)",
        (tester) async {
      final apiClient = _FakeApiClient(
        sessions: const [SkcodeSessionSummary(sid: "s-1")],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text("s-1"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SkcodeSessionScreen), findsOneWidget);
    });

    testWidgets("selectedSid highlights the matching row only when onSessionSelected is set",
        (tester) async {
      final apiClient = _FakeApiClient(
        sessions: const [
          SkcodeSessionSummary(sid: "s-1"),
          SkcodeSessionSummary(sid: "s-2"),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              onSessionSelected: (_) {},
              selectedSid: "s-2",
            ),
          ),
        ),
      );
      await tester.pump();

      final tileS1 = tester.widget<ListTile>(
        find.ancestor(of: find.text("s-1"), matching: find.byType(ListTile)),
      );
      final tileS2 = tester.widget<ListTile>(
        find.ancestor(of: find.text("s-2"), matching: find.byType(ListTile)),
      );
      expect(tileS1.selected, isFalse);
      expect(tileS2.selected, isTrue);
    });

    testWidgets("headerChip renders above the list when supplied, absent when null",
        (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              headerChip: const Text("MY CHIP"),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text("MY CHIP"), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text("MY CHIP"), findsNothing);
    });

    testWidgets("projectChatBuilder is forwarded to the pushed SkcodeSessionScreen "
        "along with the tapped session's own repo", (tester) async {
      final apiClient = _FakeApiClient(
        sessions: const [SkcodeSessionSummary(sid: "s-1", repo: "skworld-app")],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SkcodeSessionsRail(
              apiClient: apiClient,
              origin: "http://localhost:9384",
              mintToken: () async => "T",
              onAuthRejected: () {},
              projectChatBuilder: (context, repo) => Text("CHAT $repo"),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text("s-1"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final screen = tester.widget<SkcodeSessionScreen>(find.byType(SkcodeSessionScreen));
      expect(screen.repo, "skworld-app");
      expect(screen.projectChatBuilder, isNotNull);
    });
  });
}

class _FakeAuth implements AuthContext {
  const _FakeAuth({this.scopes = const {}});

  @override
  final Set<String> scopes;

  @override
  String get audience => "skcode";
  @override
  String? get subjectFqid => "agent:test@skworld.io";
  @override
  bool hasScope(String scope) => scopes.contains(scope);
  @override
  Future<String?> token() async => "T";
}
