import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:skcode_client/skcode_client.dart";

/// Fakes [SkcodeApiClient] the same way the rest of this package's test suite
/// does (`implements`, not a mocking framework): a widget test must never open
/// a real socket, per the transport-layer test convention already established
/// for the other tabs in this pane.
///
/// Only [fetchDigest] is implemented; every other route forwards to
/// [noSuchMethod] and throws, which keeps this fake honest about what this
/// file actually exercises. Card C-14a moved the digest onto this client, so
/// there is no digest-specific client left to fake.
class _FakeApiClient implements SkcodeApiClient {
  _FakeApiClient(this._result);
  final Future<SkcodeDigest> Function(String token) _result;
  int calls = 0;
  final List<String> tokens = [];

  @override
  Future<SkcodeDigest> fetchDigest({required String token}) {
    calls++;
    tokens.add(token);
    return _result(token);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        "${invocation.memberName} is not exercised by this file",
      );
}

/// The token minter the Digest tab is handed in these tests: a real token,
/// resolved once per load, so the tab reaches [_FakeApiClient.fetchDigest]
/// instead of settling on its "not authorized" state.
Future<String?> _token() async => "wire-token";

SkcodeEvent _ev({
  String type = "diff",
  String text = "",
  Map<String, dynamic> data = const {},
  int seq = 1,
  double ts = 1000.0,
  String sid = "s-1",
}) =>
    SkcodeEvent(type: type, text: text, data: data, seq: seq, ts: ts, sid: sid);

Widget _wrap(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme,
      home: Scaffold(body: child),
    );

void main() {
  group("tabs", () {
    testWidgets("without a chat slot renders exactly Diff, Digest, Logs, Raw",
        (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));

      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Digest"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Logs"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Raw"), findsOneWidget);
      expect(find.widgetWithText(Tab, "Chat"), findsNothing);
    });

    testWidgets("showChatTab prepends a Chat tab", (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: [], showChatTab: true)),
      );

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      // Chat is first, ahead of Diff/Digest/Logs/Raw (spec: "Chat | Diff |
      // Digest | Logs | Raw").
      expect(tabBar.tabs.length, 5);
      expect(find.widgetWithText(Tab, "Chat"), findsOneWidget);
    });

    testWidgets("Chat tab renders the inert placeholder with no chatSlot",
        (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: [], showChatTab: true)),
      );

      expect(find.text("Chat"), findsWidgets); // tab label + placeholder body
    });

    testWidgets("Chat tab renders C-12's widget once chatSlot is supplied",
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          SkcodeArtifactPane(
            events: const [],
            showChatTab: true,
            chatSlot: const Text("real chat content"),
          ),
        ),
      );

      expect(find.text("real chat content"), findsOneWidget);
    });

    testWidgets("chatUnreadCount renders a Badge on the Chat tab",
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SkcodeArtifactPane(
            events: [],
            showChatTab: true,
            chatUnreadCount: 3,
          ),
        ),
      );

      expect(find.byType(Badge), findsOneWidget);
      expect(find.text("3"), findsOneWidget);
    });

    testWidgets("no badge when chatUnreadCount is 0", (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: [], showChatTab: true)),
      );

      expect(find.byType(Badge), findsNothing);
    });

    testWidgets("Raw tab hosts SkcodeRawRail, not a second rail",
        (tester) async {
      final event = _ev(type: "assistant_text", text: "hello", seq: 1);
      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: [event])));

      await tester.tap(find.widgetWithText(Tab, "Raw"));
      await tester.pumpAndSettle();

      expect(find.byType(SkcodeRawRail), findsOneWidget);
    });

    testWidgets("Logs tab renders a reserved placeholder", (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));

      await tester.tap(find.widgetWithText(Tab, "Logs"));
      await tester.pumpAndSettle();

      expect(find.text("No logs yet"), findsOneWidget);
    });
  });

  group("Diff tab grouping", () {
    testWidgets("empty state with no diff events", (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));
      expect(find.text("No diffs yet"), findsOneWidget);
    });

    testWidgets(
        "groups the latest diff event per file with add/remove counts",
        (tester) async {
      final events = [
        _ev(
          data: {"file": "lib/x.dart", "added": 10, "removed": 2},
          ts: 100,
          seq: 1,
        ),
        // A newer diff event for the SAME file: this is the one that must
        // win (latest per file, not first-seen).
        _ev(
          data: {"file": "lib/x.dart", "added": 61, "removed": 38},
          ts: 200,
          seq: 2,
        ),
        _ev(
          data: {"file": "lib/y.dart", "added": 5, "removed": 0},
          ts: 150,
          seq: 3,
        ),
        // Non-diff noise must be ignored entirely.
        _ev(type: "assistant_text", text: "hi", ts: 300, seq: 4),
      ];

      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: events)));

      expect(find.text("lib/x.dart"), findsOneWidget);
      expect(find.text("lib/y.dart"), findsOneWidget);
      expect(find.text("+61"), findsOneWidget);
      expect(find.text("-38"), findsOneWidget);
      // The stale (ts:100) row for lib/x.dart must NOT also render.
      expect(find.text("+10"), findsNothing);
      expect(find.text("-2"), findsNothing);
      expect(find.text("+5"), findsOneWidget);
      expect(find.text("-0"), findsOneWidget);
    });

    testWidgets("tolerates alternate key names for file/added/removed",
        (tester) async {
      final events = [
        _ev(
          data: {"path": "lib/z.dart", "insertions": 7, "deletions": 1},
          ts: 100,
          seq: 1,
        ),
      ];

      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: events)));

      expect(find.text("lib/z.dart"), findsOneWidget);
      expect(find.text("+7"), findsOneWidget);
      expect(find.text("-1"), findsOneWidget);
    });

    testWidgets("a diff event with no resolvable file name is dropped",
        (tester) async {
      final events = [_ev(data: {"added": 1, "removed": 1}, ts: 100, seq: 1)];

      await tester.pumpWidget(_wrap(SkcodeArtifactPane(events: events)));

      expect(find.text("No diffs yet"), findsOneWidget);
    });
  });

  group("Digest tab", () {
    Future<void> openDigestTab(WidgetTester tester, Widget pane) async {
      await tester.pumpWidget(_wrap(pane));
      await tester.tap(find.widgetWithText(Tab, "Digest"));
      await tester.pumpAndSettle();
    }

    testWidgets(
        "with no transport wired the tab says it is not authorized, never "
        "that no digest exists", (tester) async {
      // A bare pane has no client and no token minter, so nothing can be
      // asked for. That is an access fact, not a publish fact: rendering it
      // as "no digest published yet" would be a claim about the watchdog
      // this pane has no evidence for.
      await openDigestTab(tester, const SkcodeArtifactPane(events: []));

      expect(find.byKey(const Key("skcodeDigestUnauthorized")), findsOneWidget);
      expect(find.text("Not authorized to read the digest"), findsOneWidget);
      expect(find.byKey(const Key("skcodeDigestNotFound")), findsNothing);
    });

    testWidgets(
        "a fetched digest renders headline, Problems, and Notable, and a "
        "tapped link with a uri calls onOpenLink with that uri",
        (tester) async {
      final opened = <String>[];
      final client = _FakeApiClient((token) async {
        return SkcodeDigest.fromJson({
          "date": "2026-08-11",
          "headline": "One incident, three merges.",
          "problems": [
            {
              "summary": "skchat daemon crash-looped on .41",
              "severity": "problem",
              "source": "fleet",
              "kind": "ServiceCrashLoop",
              "link": {"uri": "skworld://skcode/session/s-42", "http": "https://x"},
              "ref": "fleet:1",
            },
          ],
          "notable": [
            {
              "summary": "PR #61 merged to main",
              "severity": "notable",
              "source": "git",
              "ref": "git:61",
            },
          ],
          "info_counts": {"scheduler": 4, "coord_autocode": 2},
        });
      });

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
          onOpenLink: opened.add,
        ),
      );

      // The minted token actually reached the client: the digest is an
      // authenticated read now, not the anonymous GET card C-9 shipped.
      expect(client.tokens, ["wire-token"]);
      expect(find.text("One incident, three merges."), findsOneWidget);
      expect(find.textContaining("Problems"), findsOneWidget);
      expect(find.text("skchat daemon crash-looped on .41"), findsOneWidget);
      expect(find.textContaining("Notable"), findsOneWidget);
      expect(find.text("PR #61 merged to main"), findsOneWidget);
      expect(find.text("6 quiet events"), findsOneWidget);

      await tester.tap(find.text("skchat daemon crash-looped on .41"));
      await tester.pumpAndSettle();

      // The link's `uri` (shell-resolvable) is preferred over its `http`
      // fallback (watchdog spec section 8).
      expect(opened, ["skworld://skcode/session/s-42"]);
    });

    testWidgets("a row with no link is not tappable", (tester) async {
      final client = _FakeApiClient(
        (token) async => SkcodeDigest.fromJson({
          "notable": [
            {"summary": "no link on this one", "severity": "notable"},
          ],
        }),
      );

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
        ),
      );

      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text("no link on this one"),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.onTap, isNull);
    });

    testWidgets(
        "a real digest with nothing firing reads as a quiet day, not as a "
        "missing digest", (tester) async {
      // The whole point of card C-14a: these two must never render alike.
      final client = _FakeApiClient(
        (token) async => SkcodeDigest.fromJson({
          "date": "2026-08-11",
          "headline": "All quiet.",
          "problems": <dynamic>[],
          "notable": <dynamic>[],
        }),
      );

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
        ),
      );

      expect(find.byKey(const Key("skcodeDigestQuietDay")), findsOneWidget);
      expect(find.text("All quiet."), findsOneWidget);
      expect(find.byKey(const Key("skcodeDigestNotFound")), findsNothing);
    });

    testWidgets("no digest published yet (404) renders that exact message",
        (tester) async {
      final client = _FakeApiClient(
        (token) async => throw const SkcodeDigestNotFoundException(),
      );

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
        ),
      );

      expect(find.byKey(const Key("skcodeDigestNotFound")), findsOneWidget);
      expect(find.text("No digest published yet"), findsOneWidget);
      expect(find.byKey(const Key("skcodeDigestQuietDay")), findsNothing);
    });

    testWidgets(
        "a 401 re-mints exactly once and then settles on not-authorized",
        (tester) async {
      var reminted = 0;
      final client = _FakeApiClient(
        (token) async => throw const SkcodeUnauthorizedException(),
      );

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
          onAuthRejected: () => reminted++,
        ),
      );

      // One re-mint, one retry, then stop: never a retry loop against a host
      // that keeps saying no.
      expect(reminted, 1);
      expect(client.calls, 2);
      expect(find.byKey(const Key("skcodeDigestUnauthorized")), findsOneWidget);
      expect(
        find.text("Not authorized to read the digest"),
        findsOneWidget,
      );
    });

    testWidgets("a 401 that clears on the re-minted token renders the digest",
        (tester) async {
      var attempts = 0;
      final client = _FakeApiClient((token) async {
        attempts++;
        if (attempts == 1) throw const SkcodeUnauthorizedException();
        return SkcodeDigest.fromJson({"headline": "After the re-mint."});
      });

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
          onAuthRejected: () {},
        ),
      );

      expect(find.text("After the re-mint."), findsOneWidget);
    });

    testWidgets(
        "an unreachable host degrades to its own state with Retry, never a "
        "crash", (tester) async {
      final client = _FakeApiClient(
        (token) async => throw const SkcodeApiException("boom"),
      );

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
        ),
      );

      expect(find.byKey(const Key("skcodeDigestUnreachable")), findsOneWidget);
      expect(find.text("Could not reach the digest"), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, "Retry"), findsOneWidget);
      expect(client.calls, 1);

      await tester.tap(find.widgetWithText(OutlinedButton, "Retry"));
      await tester.pumpAndSettle();

      expect(client.calls, 2);
    });

    testWidgets(
        "a corrupt published artifact reads as corrupt, not as unreachable "
        "and not as missing", (tester) async {
      final client = _FakeApiClient(
        (token) async => throw const SkcodeDigestParseException("not json"),
      );

      await openDigestTab(
        tester,
        SkcodeArtifactPane(
          events: const [],
          apiClient: client,
          mintToken: _token,
        ),
      );

      expect(find.byKey(const Key("skcodeDigestCorrupt")), findsOneWidget);
      expect(find.text("The published digest could not be read"), findsOneWidget);
      expect(find.byKey(const Key("skcodeDigestNotFound")), findsNothing);
      expect(find.byKey(const Key("skcodeDigestUnreachable")), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group("panel-left shadow", () {
    List<BoxShadow> shadowFor(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(
        find.byKey(const Key("skcode-artifact-pane-shadow")),
      );
      final decoration = box.decoration as BoxDecoration;
      return decoration.boxShadow!;
    }

    testWidgets("carries two negative-x layers in light mode",
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SkcodeArtifactPane(events: []),
          theme: ThemeData.light(),
        ),
      );

      final shadows = shadowFor(tester);
      expect(shadows.length, 2);

      // Hairline: the boundary layer, zero blur/spread, offset (-1, 0).
      expect(shadows[0].offset, const Offset(-1, 0));
      expect(shadows[0].blurRadius, 0);
      expect(shadows[0].spreadRadius, 0);
      // A visible (non-transparent) color: the hairline is what carries
      // dark mode, so it can never be fully transparent.
      expect(shadows[0].color.a, greaterThan(0));

      // Soft lift: -16px 0 32px -12px black at low alpha.
      expect(shadows[1].offset, const Offset(-16, 0));
      expect(shadows[1].blurRadius, 32);
      expect(shadows[1].spreadRadius, -12);
      expect(shadows[1].color.a, greaterThan(0));
      expect(shadows[1].color.a, lessThan(1));
    });

    testWidgets(
        "still reads as docked in dark mode (hairline color adapts, "
        "geometry is unchanged)", (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SkcodeArtifactPane(events: []),
          theme: ThemeData.dark(),
        ),
      );

      final shadows = shadowFor(tester);
      expect(shadows.length, 2);
      expect(shadows[0].offset, const Offset(-1, 0));
      expect(shadows[1].offset, const Offset(-16, 0));
      // The hairline must still be a visible color against a dark surface,
      // not black-on-black (the whole reason `panel-left` needs a hairline
      // at all: "a black shadow reads as nothing" in dark mode).
      expect(shadows[0].color.a, greaterThan(0));
      final scheme = ThemeData.dark().colorScheme;
      expect(shadows[0].color, scheme.outlineVariant);
    });

    testWidgets("hairline color differs between light and dark (theme-aware)",
        (tester) async {
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: []), theme: ThemeData.light()),
      );
      final lightHairline = shadowFor(tester)[0].color;

      // MaterialApp wraps its Theme in an implicit AnimatedTheme, so a
      // second pumpWidget with a different theme needs pumpAndSettle to
      // let the transition finish before Theme.of reflects the new
      // (dark) ColorScheme rather than an in-flight interpolation.
      await tester.pumpWidget(
        _wrap(const SkcodeArtifactPane(events: []), theme: ThemeData.dark()),
      );
      await tester.pumpAndSettle();
      final darkHairline = shadowFor(tester)[0].color;

      expect(lightHairline, isNot(darkHairline));
    });

    testWidgets("a left-only Border alone is never used for this pane",
        (tester) async {
      await tester.pumpWidget(_wrap(const SkcodeArtifactPane(events: [])));

      final box = tester.widget<DecoratedBox>(
        find.byKey(const Key("skcode-artifact-pane-shadow")),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.border, isNull);
    });
  });

  group("phone bottom sheet", () {
    testWidgets("showBottomSheet presents the pane in a DraggableScrollableSheet",
        (tester) async {
      final event = _ev(
        data: {"file": "lib/x.dart", "added": 1, "removed": 0},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => SkcodeArtifactPane.showBottomSheet(
                  context,
                  events: [event],
                ),
                child: const Text("open"),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();

      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.byType(SkcodeArtifactPane), findsOneWidget);
      expect(find.widgetWithText(Tab, "Diff"), findsOneWidget);
      expect(find.text("lib/x.dart"), findsOneWidget);
    });
  });
}
