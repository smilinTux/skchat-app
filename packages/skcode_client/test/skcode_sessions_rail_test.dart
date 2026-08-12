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
  _FakeApiClient({this.sessions = const []});

  final List<SkcodeSessionSummary> sessions;

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async =>
      sessions;

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

    expect(find.text("No sessions yet"), findsOneWidget);
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
