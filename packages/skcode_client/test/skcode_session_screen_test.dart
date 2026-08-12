import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";
import "package:skworld_module_api/skworld_module_api.dart";

/// A controllable [SkcodeWsTransport]: tests push frames via [emit]. Mirrors
/// `skcode_session_store_test.dart`'s fake so no test opens a real socket.
class _FakeWsTransport implements SkcodeWsTransport {
  final _streamController = StreamController<dynamic>.broadcast();
  int? _closeCode;

  @override
  Future<void> get ready async {}
  @override
  Stream<dynamic> get stream => _streamController.stream;
  @override
  int? get closeCode => _closeCode;
  @override
  Future<void> close() async {
    if (!_streamController.isClosed) await _streamController.close();
  }

  void emit(Map<String, dynamic> frame) => _streamController.add(jsonEncode(frame));
}

/// The pre-C-5 tests in this file exercise no archive and no write route:
/// the empty-archive default is realistic enough (a freshly opened session
/// with no history yet). The card C-5 tests below configure [archive]
/// directly (skipping the WS transport entirely, which stays a
/// never-resolving fake for those cases: this is the composer/banner's own
/// wiring, not the live-tail reconnect machinery `skcode_session_store_test.dart`
/// already covers) and record every inject/ratify call so a test can assert
/// on the exact route + payload without a real Dio adapter.
class _FakeApiClient implements SkcodeApiClient {
  _FakeApiClient({this.archive = const []});

  final List<SkcodeEvent> archive;

  final List<({String sid, String text})> injectCalls = [];
  final List<String> ratifyCalls = [];

  /// When set, the next `injectText`/`ratifySession` call throws this
  /// instead of recording/succeeding (a network-failure test seam).
  Object? failWith;

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async => const [];

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async =>
      archive;

  @override
  Future<List<SkcodeJobRun>> listJobs({required String token}) async {
    throw UnimplementedError("not exercised by SkcodeSessionScreen tests");
  }

  @override
  Future<void> injectText(String sid, String text, {required String token}) async {
    final err = failWith;
    if (err != null) throw err;
    injectCalls.add((sid: sid, text: text));
  }

  @override
  Future<void> ratifySession(String sid, {required String token}) async {
    final err = failWith;
    if (err != null) throw err;
    ratifyCalls.add(sid);
  }
}

/// A minimal [AuthContext] test double: [scopes] drives [hasScope] exactly
/// like the real audience-scoped context does.
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

void main() {
  testWidgets("defaults to the transcript view", (tester) async {
    final apiClient = _FakeApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: SkcodeSessionScreen(
          sid: "s-1",
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SkcodeTranscriptList), findsOneWidget);
    expect(find.byType(SkcodeRawRail), findsNothing);
  });

  testWidgets(
    "the raw rail toggle REPLACES the transcript exclusively (spec section 7: "
    "phone maps side to exclusive), never both at once",
    (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeTranscriptList), findsOneWidget);
      expect(find.byType(SkcodeRawRail), findsNothing);

      await tester.tap(find.byIcon(Icons.data_object));
      await tester.pump();

      expect(find.byType(SkcodeTranscriptList), findsNothing);
      expect(find.byType(SkcodeRawRail), findsOneWidget);

      await tester.tap(find.byIcon(Icons.forum_outlined));
      await tester.pump();

      expect(find.byType(SkcodeTranscriptList), findsOneWidget);
      expect(find.byType(SkcodeRawRail), findsNothing);
    },
  );

  testWidgets("live WS frames update both the transcript and the raw rail", (tester) async {
    final apiClient = _FakeApiClient();
    late _FakeWsTransport transport;

    await tester.pumpWidget(
      MaterialApp(
        home: SkcodeSessionScreen(
          sid: "s-1",
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) {
            transport = _FakeWsTransport();
            return transport;
          },
        ),
      ),
    );
    // pumpAndSettle drains the connect chain (archive fetch -> mint token ->
    // connectTransport -> await ready -> subscribe) via repeated frame
    // pumps; it is safe here (unlike the sessions-rail test) because this
    // screen owns no periodic Timer that would keep it from settling.
    await tester.pumpAndSettle();

    transport.emit({
      "type": "assistant_text",
      "text": "hello from the wire",
      "ts": 100.0,
      "data": <String, dynamic>{},
      "seq": 1,
      "sid": "s-1",
      "source": "interactive",
    });
    await tester.pumpAndSettle();

    expect(find.text("hello from the wire"), findsOneWidget);
  });

  testWidgets(
    "the Artifacts action presents the artifact pane as a bottom sheet "
    "(card C-7 phone entry point)",
    (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeArtifactPane), findsNothing);

      await tester.tap(find.byTooltip("Artifacts"));
      await tester.pumpAndSettle();

      expect(find.byType(SkcodeArtifactPane), findsOneWidget);
      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
    },
  );

  testWidgets("disposing the screen does not throw", (tester) async {
    final apiClient = _FakeApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: SkcodeSessionScreen(
          sid: "s-1",
          apiClient: apiClient,
          origin: "http://localhost:9384",
          mintToken: () async => "T",
          onAuthRejected: () {},
          connectTransport: (_) => _FakeWsTransport(),
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  group("card C-5: inject composer gate (AC4)", () {
    testWidgets(
        "composer is hidden entirely when the token lacks skcode.inject scope, "
        "even on an interactive session", (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeInjectComposer), findsNothing);
    });

    testWidgets(
        "composer is hidden entirely when the session is not interactive, "
        "even with skcode.inject scope", (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeInjectComposer), findsNothing);
    });

    testWidgets("composer is hidden with no AuthContext at all (standalone, fails closed)",
        (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            interactive: true,
            // auth omitted entirely.
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeInjectComposer), findsNothing);
    });

    testWidgets("composer renders when scope AND interactive are both satisfied",
        (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeInjectComposer), findsOneWidget);
      expect(find.text("INJECT -> s-1"), findsOneWidget);
    });

    testWidgets("Inject posts through apiClient.injectText with the sid and typed text",
        (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "TOKEN-A",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byKey(const Key("skcodeInjectField")), "echo hi");
      await tester.tap(find.byKey(const Key("skcodeInjectButton")));
      await tester.pumpAndSettle();

      expect(apiClient.injectCalls, hasLength(1));
      expect(apiClient.injectCalls.single.sid, "s-1");
      expect(apiClient.injectCalls.single.text, "echo hi");
    });
  });

  group("card C-5: needs_input Approve/Deny banner (AC2)", () {
    SkcodeEvent needsInputEvent({int seq = 1, String text = "ratify failed"}) => SkcodeEvent(
          type: "needs_input",
          text: text,
          ts: 100.0 + seq,
          data: const {},
          seq: seq,
          sid: "s-1",
        );

    testWidgets("pins the banner directly above the composer, not buried in the transcript",
        (tester) async {
      final apiClient = _FakeApiClient(archive: [needsInputEvent()]);

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      final bannerFinder = find.byType(SkcodeNeedsInputBanner);
      final composerFinder = find.byType(SkcodeInjectComposer);
      expect(bannerFinder, findsOneWidget);
      expect(composerFinder, findsOneWidget);
      // "Directly above": strictly smaller vertical offset than the
      // composer, and no scrollable transcript sits between them (both are
      // direct, non-scrolling children of the same Column as the
      // Expanded(transcript) sibling).
      expect(
        tester.getTopLeft(bannerFinder).dy,
        lessThan(tester.getTopLeft(composerFinder).dy),
      );
    });

    testWidgets("Approve calls ratifySession(sid) and then dismisses the banner",
        (tester) async {
      final apiClient = _FakeApiClient(archive: [needsInputEvent()]);

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SkcodeNeedsInputBanner), findsOneWidget);

      await tester.tap(find.byKey(const Key("skcodeNeedsInputApprove")));
      await tester.pumpAndSettle();

      expect(apiClient.ratifyCalls, ["s-1"]);
      expect(apiClient.injectCalls, isEmpty);
      expect(find.byType(SkcodeNeedsInputBanner), findsNothing);
    });

    testWidgets("Deny answers through inject (hostd has no dedicated deny route) "
        "and then dismisses the banner", (tester) async {
      final apiClient = _FakeApiClient(archive: [needsInputEvent()]);

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key("skcodeNeedsInputDeny")));
      await tester.pumpAndSettle();

      expect(apiClient.ratifyCalls, isEmpty);
      expect(apiClient.injectCalls, hasLength(1));
      expect(apiClient.injectCalls.single.sid, "s-1");
      expect(find.byType(SkcodeNeedsInputBanner), findsNothing);
    });

    testWidgets(
        "the banner still renders (with the composer hidden) on a non-interactive "
        "session: Approve/Deny are ratify/inject write actions, not tied to "
        "whether THIS session accepts live keystroke inject", (tester) async {
      final apiClient = _FakeApiClient(archive: [needsInputEvent()]);

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeNeedsInputBanner), findsOneWidget);
      expect(find.byType(SkcodeInjectComposer), findsNothing);
    });

    testWidgets("no banner at all without skcode.inject scope, even with a pending needs_input",
        (tester) async {
      final apiClient = _FakeApiClient(archive: [needsInputEvent()]);

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeNeedsInputBanner), findsNothing);
    });

    testWidgets("no needs_input event means no banner at all", (tester) async {
      final apiClient = _FakeApiClient();

      await tester.pumpWidget(
        MaterialApp(
          home: SkcodeSessionScreen(
            sid: "s-1",
            apiClient: apiClient,
            origin: "http://localhost:9384",
            mintToken: () async => "T",
            onAuthRejected: () {},
            connectTransport: (_) => _FakeWsTransport(),
            auth: const _FakeAuth(scopes: {"skcode.inject"}),
            interactive: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SkcodeNeedsInputBanner), findsNothing);
    });
  });
}
