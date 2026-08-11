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
    testWidgets('build(null) renders the empty shell surface standalone',
        (tester) async {
      const module = SkcodeModule();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            // ShellContext? null == standalone signal.
            builder: (context) => module.build(context, null),
          ),
        ),
      );
      expect(find.byType(SkcodeSurface), findsOneWidget);
      expect(find.text('Standalone'), findsOneWidget);
      // No mounted-only token probe renders without a shell.
      expect(find.textContaining('token'), findsNothing);
    });
  });

  group('mounted (shell != null, AppShellContext pattern)', () {
    testWidgets(
        'build(shell) renders mounted, using the shell theme, bus, and AuthContext',
        (tester) async {
      final bus = _RecordingBus();
      final shell = _FakeShell(bus: bus);
      const module = SkcodeModule();

      await tester.pumpWidget(
        MaterialApp(
          theme: shell.theme,
          home: Builder(builder: (context) => module.build(context, shell)),
        ),
      );

      // Mounted state renders, carrying the shell's audience.
      expect(find.byType(SkcodeSurface), findsOneWidget);
      expect(find.textContaining('Mounted (audience: skcode)'), findsOneWidget);

      // The bus was used: the surface emitted a mount event onto it.
      expect(bus.emitted, hasLength(1));
      expect(bus.emitted.single.name, 'skcodeMounted');

      // The AuthContext was used: token() was called and its result rendered
      // once the future settles.
      await tester.pump();
      expect(find.text('token minted'), findsOneWidget);
    });

    testWidgets('a null token from AuthContext renders the degraded state',
        (tester) async {
      final shell = _FakeShell(auth: _FakeAuth(tokenValue: null));
      const module = SkcodeModule();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) => module.build(context, shell)),
        ),
      );
      await tester.pump();

      expect(find.text('no token (running degraded)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
