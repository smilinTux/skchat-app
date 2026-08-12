import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// Mirrors the fakes already established in `skcode_module_test.dart` /
/// `skcode_sessions_rail_test.dart`: a controllable WS transport (tests push
/// frames via [emit]) so no test opens a real socket.
class _FakeWsTransport implements SkcodeWsTransport {
  final _streamController = StreamController<dynamic>.broadcast();

  @override
  Future<void> get ready async {}
  @override
  Stream<dynamic> get stream => _streamController.stream;
  @override
  int? get closeCode => null;
  @override
  Future<void> close() async {
    if (!_streamController.isClosed) await _streamController.close();
  }

  void emit(Map<String, dynamic> frame) => _streamController.add(jsonEncode(frame));
}

class _FakeApiClient implements SkcodeApiClient {
  _FakeApiClient({this.sessions = const []});

  final List<SkcodeSessionSummary> sessions;

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async => sessions;

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async =>
      const [];

  @override
  Future<List<SkcodeJobRun>> listJobs({required String token}) async => const [];

  @override
  Future<void> injectText(String sid, String text, {required String token}) async {}

  @override
  Future<void> ratifySession(String sid, {required String token}) async {}

  @override
  Future<SkcodeDispatchTargets> fetchDispatchTargets({required String token}) async {
    throw UnimplementedError("not exercised by SkcodeResponsiveBody tests");
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
    throw UnimplementedError("not exercised by SkcodeResponsiveBody tests");
  }

  @override
  Future<SkcodeCancelResult> cancelSession(String sid, {required String token}) async {
    throw UnimplementedError("not exercised by SkcodeResponsiveBody tests");
  }
}

/// Widens the ACTUAL test surface to [width]x[height] before pumping, so the
/// LayoutBuilder inside [SkcodeResponsiveBody] genuinely receives that width
/// as its own `constraints.maxWidth` (a `SizedBox` demanding more room than
/// the default 800x600 test surface would just be clamped back down to it --
/// `BoxConstraints.enforce` intersects with the INCOMING constraints, it
/// never grows past them). Resets the surface size once the test ends so
/// later tests are unaffected.
Future<void> _pumpAtWidth(
  WidgetTester tester,
  Widget body, {
  required double width,
  double height = 900,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: body)),
  );
}

void main() {
  final oneSession = [
    const SkcodeSessionSummary(sid: "s-1", repo: "skworld-app", mode: "interactive"),
  ];

  group("card C-12 AC3: tier selection driven by the pane's own width", () {
    testWidgets("phone tier (< 900) renders the plain sessions rail, no Row body",
        (tester) async {
      final apiClient = _FakeApiClient(sessions: oneSession);
      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
        ),
        width: 800,
      );
      await tester.pump();

      expect(find.byType(SkcodeSessionsRail), findsOneWidget);
      expect(find.byKey(const Key("skcodeTwoColumnBody")), findsNothing);
      expect(find.byKey(const Key("skcodeThreeColumnBody")), findsNothing);
      expect(find.byKey(const Key("skcodeWideBody")), findsNothing);

      // Phone behavior is unchanged: tapping a row PUSHES a new route.
      // Explicit pumps (never pumpAndSettle): the rail's own 15s poll Timer.
      await tester.tap(find.text("s-1"));
      await tester.pump(); // frame that starts the push transition.
      await tester.pump(const Duration(milliseconds: 400)); // transition settles.
      expect(find.byType(SkcodeSessionScreen), findsOneWidget);
    });

    testWidgets("two-column tier (900-1199) renders rail + transcript, artifact overlay closed",
        (tester) async {
      final apiClient = _FakeApiClient(sessions: oneSession);
      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
        ),
        width: 1000,
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeTwoColumnBody")), findsOneWidget);
      expect(find.byKey(const Key("skcodeArtifactOverlayToggle")), findsOneWidget);
      // Overlay starts closed: no artifact pane tabs visible yet.
      expect(find.widgetWithText(Tab, "Diff"), findsNothing);

      // Tapping a session row selects it INLINE: no navigation.
      await tester.tap(find.text("s-1"));
      await tester.pump();
      expect(find.byType(SkcodeSessionScreen), findsNothing);
      expect(find.byType(SkcodeTranscriptList), findsOneWidget);

      // Toggling the overlay reveals the artifact pane (carrying the
      // collapsed Chat tab, spec section 7 three/two-column rule).
      await tester.tap(find.byKey(const Key("skcodeArtifactOverlayToggle")));
      await tester.pump();
      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Chat"), findsOneWidget);
    });

    testWidgets(
        "three-column tier (1200-1499) renders rail + transcript + artifact pane "
        "(with Chat tab) all inline, no overlay toggle", (tester) async {
      final apiClient = _FakeApiClient(sessions: oneSession);
      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
        ),
        width: 1300,
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeThreeColumnBody")), findsOneWidget);
      expect(find.byKey(const Key("skcodeArtifactOverlayToggle")), findsNothing);
      expect(find.byType(SkcodeSessionsRail), findsOneWidget);
      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Chat"), findsOneWidget);
    });

    testWidgets(
        "wide tier (>= 1500) renders rail, project chat column, transcript, and "
        "artifact pane as FOUR simultaneous columns, no collapsed Chat tab",
        (tester) async {
      final apiClient = _FakeApiClient(sessions: oneSession);
      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
          projectChatBuilder: (context, repo) => Text("PROJECT CHAT: $repo"),
        ),
        width: 1600,
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeWideBody")), findsOneWidget);
      expect(find.byType(SkcodeSessionsRail), findsOneWidget);
      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      // Chat is its OWN column at this tier, never a collapsed tab.
      expect(find.widgetWithText(Tab, "Chat"), findsNothing);

      // No session selected yet: the chat column shows the "select a
      // session" empty state, never the repo-bound builder (nothing to
      // scope it to yet).
      expect(find.text("PROJECT CHAT: skworld-app"), findsNothing);
      expect(find.byKey(const Key("skcodeChatEmptyStateNoSession")), findsOneWidget);

      await tester.tap(find.text("s-1"));
      await tester.pump();

      // Selecting a session resolves the chat column to that session's OWN
      // repo (spec section 10: the project chat is bound per repo).
      expect(find.text("PROJECT CHAT: skworld-app"), findsOneWidget);
      expect(find.byType(SkcodeTranscriptList), findsOneWidget);
    });

    testWidgets(
        "at exactly the wide-tier floor (1500) the transcript's measured width "
        "is never below the 540 spec floor", (tester) async {
      final apiClient = _FakeApiClient();
      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
        ),
        width: kSkcodeWideBreakpoint,
      );
      await tester.pump();

      final transcriptBox =
          tester.getSize(find.byKey(const Key("skcodeTranscriptColumn")));
      expect(transcriptBox.width, greaterThanOrEqualTo(kSkcodeTranscriptMinWidth));
    });

    testWidgets("a host that never supplies projectChatBuilder degrades to an honest "
        "empty state at the wide tier, never a crash", (tester) async {
      final apiClient = _FakeApiClient(sessions: oneSession);
      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
          // projectChatBuilder omitted entirely.
        ),
        width: 1600,
      );
      await tester.pump();

      expect(find.byKey(const Key("skcodeChatEmptyStateNoBuilder")), findsOneWidget);

      await tester.tap(find.text("s-1"));
      await tester.pump();

      // Still the no-builder empty state (never crashes, never falls
      // through to the no-session empty state instead).
      expect(find.byKey(const Key("skcodeChatEmptyStateNoBuilder")), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group("EXIT TEST (card C-12): ask in chat, watch the Diff tab update, no tab switch",
      () {
    testWidgets(
        "at the wide tier, a diff event arriving on the selected session's WS tail "
        "updates the artifact pane's Diff tab while the chat column stays mounted, "
        "untouched, with no tab switch performed", (tester) async {
      final apiClient = _FakeApiClient(sessions: oneSession);
      late _FakeWsTransport transport;

      await _pumpAtWidth(
        tester,
        SkcodeResponsiveBody(
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) {
            transport = _FakeWsTransport();
            return transport;
          },
          projectChatBuilder: (context, repo) => Text("PROJECT CHAT: $repo"),
        ),
        width: 1600,
      );
      await tester.pump();

      // Explicit pumps (never pumpAndSettle): SkcodeSessionsListStore's 15s
      // poll Timer.periodic on the rail inline in this SAME tree would keep
      // pumpAndSettle waiting forever (see skcode_sessions_rail_test.dart's
      // identical note). A couple of bounded pumps is enough to drain the
      // session store's own connect chain (mint token -> fetch archive ->
      // connect -> await ready -> subscribe), all fake-resolved with no
      // real delay.
      await tester.tap(find.text("s-1"));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Both surfaces visible simultaneously BEFORE the diff lands: this is
      // the whole point of the four-column tier (chat on the left,
      // transcript+artifact on the right, no tab to switch between them).
      expect(find.text("PROJECT CHAT: skworld-app"), findsOneWidget);
      expect(find.text("No diffs yet"), findsOneWidget);

      transport.emit({
        "type": "diff",
        "text": "",
        "ts": 100.0,
        "data": <String, dynamic>{"file": "lib/main.dart", "added": 12, "removed": 3},
        "seq": 1,
        "sid": "s-1",
        "source": "interactive",
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The Diff tab updated in place; the chat column is still exactly
      // where it was, never remounted or navigated away from.
      expect(find.text("No diffs yet"), findsNothing);
      expect(find.text("lib/main.dart"), findsOneWidget);
      expect(find.text("+12"), findsOneWidget);
      expect(find.text("PROJECT CHAT: skworld-app"), findsOneWidget);
    });
  });
}
