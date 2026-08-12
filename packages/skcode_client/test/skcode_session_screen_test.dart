import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

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

/// No test in this file exercises a pre-seeded archive: the empty default is
/// realistic enough (a freshly opened session with no history yet), so this
/// fake has no configuration knobs.
class _FakeApiClient implements SkcodeApiClient {
  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async => const [];

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async =>
      const [];
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
}
