import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skworld_module_api/skworld_module_api.dart';
import 'package:skcode_client/skcode_client.dart';

// --- Minimal shell fakes so the mounted path has a non-null ShellContext. ----
//
// These mirror the concrete shapes the app hands a mounted module in
// `lib/features/shell/module_host_screen.dart` / `app_shell_context.dart`
// (AppShellContext / AppAuthContext / AppShellBus): a theme, a bus that
// records what it is asked to do, and an AuthContext whose token() never
// throws. This package cannot import the app (import gate), so it mirrors
// the pattern locally with its own fakes, exactly as
// `packages/skchat_ui/test/skchat_module_test.dart` does for skchat.

class _FakeAuth implements AuthContext {
  _FakeAuth({this.tokenValue = 'audience-scoped-token'});

  final String? tokenValue;

  @override
  String get audience => 'skcode';
  @override
  String? get subjectFqid => 'agent:lumina@skworld.io';
  @override
  Set<String> get scopes => const {'skcode.stream'};
  @override
  bool hasScope(String scope) => scopes.contains(scope);
  @override
  Future<String?> token() async => tokenValue;
}

/// A bus that records what it is asked to do, so mounted usage can be
/// asserted (the "uses the shell's ... bus" acceptance criterion).
class _RecordingBus implements ShellBus {
  final List<String> navigated = [];
  final List<ShellEvent> emitted = [];

  @override
  void navigate(String deeplink) => navigated.add(deeplink);
  @override
  void emit(ShellEvent event) => emitted.add(event);
  @override
  Stream<ShellEvent> get events => const Stream.empty();
}

class _FakeShell implements ShellContext {
  _FakeShell({AuthContext? auth, ShellBus? bus, ThemeData? theme})
      : _auth = auth ?? _FakeAuth(),
        _bus = bus ?? _RecordingBus(),
        _theme = theme ?? ThemeData(brightness: Brightness.dark);

  final AuthContext _auth;
  final ShellBus _bus;
  final ThemeData _theme;

  @override
  AuthContext get auth => _auth;
  @override
  ShellBus get bus => _bus;
  @override
  ThemeData get theme => _theme;
}

/// A [SkcodeApiClient] fake so no test opens a real socket (card C-4: the
/// module now polls `GET /sessions` on mount whenever `mintToken` resolves
/// non-null, which it does in every mounted test here).
class _FakeApiClient implements SkcodeApiClient {
  _FakeApiClient({this.sessions = const []});

  final List<SkcodeSessionSummary> sessions;
  int listCalls = 0;

  @override
  Future<List<SkcodeSessionSummary>> listSessions({required String token}) async {
    listCalls++;
    return sessions;
  }

  @override
  Future<List<SkcodeEvent>> fetchEventsPage(
    String sid, {
    required String token,
    int? beforeSeq,
    int limit = 100,
  }) async {
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
  }

  @override
  Future<List<SkcodeJobRun>> listJobs({required String token}) async {
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
  }

  @override
  Future<void> injectText(String sid, String text, {required String token}) async {
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
  }

  @override
  Future<void> ratifySession(String sid, {required String token}) async {
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
  }

  @override
  Future<SkcodeDispatchTargets> fetchDispatchTargets({required String token}) async {
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
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
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
  }

  @override
  Future<SkcodeCancelResult> cancelSession(String sid, {required String token}) async {
    throw UnimplementedError('not exercised by SkcodeModule/SkcodeSurface tests');
  }
}

/// Fakes [SkcodeDigestClient] (see `skcode_artifact_pane_test.dart`'s
/// identical fake for the same rationale: never open a real socket).
class _FakeDigestClient implements SkcodeDigestClient {
  _FakeDigestClient(this._result);
  final Future<SkcodeDigest> Function(String url) _result;

  @override
  Future<SkcodeDigest> fetchLatest(String url) => _result(url);
}

void main() {
  test('SkcodeModule instantiates and is a SkworldModule', () {
    const module = SkcodeModule();
    expect(module, isA<SkworldModule>());
  });

  test('nav metadata matches the skcode manifest block (spec section 4.1)',
      () {
    const module = SkcodeModule();
    expect(module.id, 'skcode');
    expect(module.nav.label, 'Code');
    expect(module.nav.icon, Icons.terminal);
    expect(module.nav.order, 15);
    expect(module.nav.deeplinkPrefix, 'skworld://skcode/');
  });

  group('standalone (shell == null)', () {
    testWidgets(
        'build(null) renders the sessions rail standalone (card C-4)',
        (tester) async {
      // No shell means no AuthContext, so mintToken resolves null and the
      // sessions poll never even calls listSessions: no fake apiClient is
      // required for this path to stay off the network (see
      // SkcodeSessionsListStore._poll's null-token early return). Card
      // C-19: a never-minted token renders the same "No access yet" state
      // as a rejected one, not the empty-list state.
      const module = SkcodeModule();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            // ShellContext? null == standalone signal.
            builder: (context) => module.build(context, null),
          ),
        ),
      );
      // Card C-19: the rail renders nothing for the one beat before its
      // first poll resolves (never guesses a state), same as
      // `_JobsSection`'s null-snapshot beat -- so this needs an explicit
      // pump to let that first (tokenless) poll settle before asserting on
      // its result, unlike the old synchronous-default "No sessions yet"
      // this replaced.
      await tester.pump();
      expect(find.byType(SkcodeSurface), findsOneWidget);
      expect(find.byType(SkcodeSessionsRail), findsOneWidget);
      expect(find.text('Code'), findsOneWidget); // AppBar title.
      expect(find.text('No access yet'), findsOneWidget);
    });
  });

  group('mounted (shell != null, AppShellContext pattern)', () {
    testWidgets(
        'build(shell) renders mounted, using the shell theme, bus, and AuthContext',
        (tester) async {
      final bus = _RecordingBus();
      final shell = _FakeShell(bus: bus);
      final apiClient = _FakeApiClient(
        sessions: [const SkcodeSessionSummary(sid: 's-1a2b', harness: 'claude-code')],
      );
      final module = SkcodeModule(apiClient: apiClient);

      await tester.pumpWidget(
        MaterialApp(
          theme: shell.theme,
          home: Builder(builder: (context) => module.build(context, shell)),
        ),
      );

      // Mounted state renders the sessions rail.
      expect(find.byType(SkcodeSurface), findsOneWidget);
      expect(find.byType(SkcodeSessionsRail), findsOneWidget);

      // The bus was used: the surface emitted a mount event onto it.
      expect(bus.emitted, hasLength(1));
      expect(bus.emitted.single.name, 'skcodeMounted');

      // The AuthContext was used for real work: mintToken drove the
      // sessions poll, which called the fake apiClient and rendered its
      // result once the future settles.
      await tester.pump();
      expect(apiClient.listCalls, greaterThanOrEqualTo(1));
      expect(find.text('s-1a2b'), findsOneWidget);
    });

    testWidgets('a null token from AuthContext renders the degraded state',
        (tester) async {
      final shell = _FakeShell(auth: _FakeAuth(tokenValue: null));
      final apiClient = _FakeApiClient();
      final module = SkcodeModule(apiClient: apiClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) => module.build(context, shell)),
        ),
      );
      await tester.pump();

      expect(find.text('No access yet'), findsOneWidget);
      // A null-token poll must never reach the transport at all.
      expect(apiClient.listCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the Digest action defaults onOpenLink to shell.bus.navigate, '
        'proving a tapped link actually reaches the shell router (card C-9)',
        (tester) async {
      final bus = _RecordingBus();
      final shell = _FakeShell(bus: bus);
      final apiClient = _FakeApiClient();
      final digestClient = _FakeDigestClient((url) async {
        expect(url, 'https://atlas.skworld.io/watchdog/latest/digest.json');
        return SkcodeDigest.fromJson({
          'headline': 'One thing happened.',
          'problems': [
            {
              'summary': 'crash looped',
              'severity': 'problem',
              'link': {'uri': 'skworld://skcode/session/s-9'},
            },
          ],
        });
      });
      final module = SkcodeModule(
        apiClient: apiClient,
        digestUrl: 'https://atlas.skworld.io/watchdog/latest/digest.json',
        digestClient: digestClient,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: shell.theme,
          home: Builder(builder: (context) => module.build(context, shell)),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Digest'));
      await tester.pumpAndSettle();

      expect(find.text('One thing happened.'), findsOneWidget);
      await tester.tap(find.text('crash looped'));
      await tester.pumpAndSettle();

      // No onOpenLink was supplied to the module, so SkcodeSurface fell back
      // to shell.bus.navigate: the same "shell router" call skchat's own
      // deep links use, proving the link actually reaches it and is not
      // merely rendered inert.
      expect(bus.navigated, ['skworld://skcode/session/s-9']);
    });

    testWidgets(
        'an explicit onOpenLink overrides the shell.bus.navigate default',
        (tester) async {
      final bus = _RecordingBus();
      final shell = _FakeShell(bus: bus);
      final apiClient = _FakeApiClient();
      final digestClient = _FakeDigestClient(
        (url) async => SkcodeDigest.fromJson({
          'notable': [
            {
              'summary': 'merged',
              'severity': 'notable',
              'link': {'uri': 'skworld://skchat/thread/x'},
            },
          ],
        }),
      );
      final opened = <String>[];
      final module = SkcodeModule(
        apiClient: apiClient,
        digestUrl: 'https://x/digest.json',
        digestClient: digestClient,
        onOpenLink: opened.add,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: shell.theme,
          home: Builder(builder: (context) => module.build(context, shell)),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('merged'));
      await tester.pumpAndSettle();

      expect(opened, ['skworld://skchat/thread/x']);
      // The bus itself was never asked to navigate: the explicit override
      // took the call instead of the default.
      expect(bus.navigated, isEmpty);
    });

    testWidgets(
        'standalone (no shell) leaves a tapped digest link inert, never a '
        'crash', (tester) async {
      final digestClient = _FakeDigestClient(
        (url) async => SkcodeDigest.fromJson({
          'notable': [
            {
              'summary': 'no router here',
              'severity': 'notable',
              'link': {'uri': 'skworld://skcode/session/s-1'},
            },
          ],
        }),
      );
      final module = SkcodeModule(
        digestUrl: 'https://x/digest.json',
        digestClient: digestClient,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) => module.build(context, null)),
        ),
      );

      await tester.tap(find.byTooltip('Digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Digest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('no router here'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
