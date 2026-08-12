import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/router/app_router.dart';
import 'package:skchat/features/shell/app_shell_context.dart';

/// Card C-9: proves `skworld://skcode/...` deep links resolve through the
/// shell router (watchdog spec section 8/9: "the shell router is where those
/// links were always meant to land"), mirroring `module_host_test.dart`'s
/// `mapSkchatDeeplink`/`AppShellBus` coverage exactly, one level for skcode's
/// own authority.
///
/// Card C-10 (the Grade A registry flip, deliberately last) has not landed a
/// live screen at [AppRoutes.codeSession]/[AppRoutes.codeDigest] yet, so the
/// strongest available proof today is: the pure mapping function is correct,
/// AND [AppShellBus.navigate] (the real production entry point every mounted
/// module calls through `ShellBus.navigate`) drives a REAL [GoRouter] to the
/// mapped route. That second part is the "actually routes, not merely
/// renders" bar: a spy screen appears at the destination the router itself
/// resolved, not a string a test merely inspects.
class _SpyScreen extends StatelessWidget {
  const _SpyScreen({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('SPY:$label')));
}

void main() {
  group('mapSkcodeDeeplink', () {
    test('session deep link maps to the session route', () {
      expect(
        mapSkcodeDeeplink('skworld://skcode/session/s-42'),
        '/code/s/s-42',
      );
    });

    test('digest deep link maps to the digest route', () {
      expect(mapSkcodeDeeplink('skworld://skcode/digest'), '/code/digest');
    });

    test('bare authority maps to the code landing route', () {
      expect(mapSkcodeDeeplink('skworld://skcode/'), '/code');
    });

    test('unknown segment and session-with-no-id map to null', () {
      expect(mapSkcodeDeeplink('skworld://skcode/bogus'), isNull);
      expect(mapSkcodeDeeplink('skworld://skcode/session'), isNull);
    });

    test('a foreign authority or unparseable link maps to null', () {
      expect(mapSkcodeDeeplink('skworld://skchat/thread/abc'), isNull);
      expect(mapSkcodeDeeplink('not a uri at all ::://'), isNull);
    });
  });

  group('AppShellBus dispatches skcode links (generalized shell router)', () {
    test('navigate on a skworld://skcode/session/<sid> link calls onNavigate '
        'with the mapped route', () {
      final seen = <String>[];
      final bus = AppShellBus(onNavigate: seen.add);
      bus.navigate('skworld://skcode/session/s-42');
      expect(seen, ['/code/s/s-42']);
      bus.dispose();
    });

    test('navigate on skworld://skcode/digest calls onNavigate with /code/digest',
        () {
      final seen = <String>[];
      final bus = AppShellBus(onNavigate: seen.add);
      bus.navigate('skworld://skcode/digest');
      expect(seen, ['/code/digest']);
      bus.dispose();
    });

    test('skchat links still resolve on the same bus (no regression from '
        'generalizing navigate to try multiple modules)', () {
      final seen = <String>[];
      final bus = AppShellBus(onNavigate: seen.add);
      bus.navigate('skworld://skchat/thread/x');
      expect(seen, ['/chats/x']);
      bus.dispose();
    });

    test('an unmapped skcode link degrades to onUnhandled, never a crash',
        () {
      final navigated = <String>[];
      final unhandled = <String>[];
      final bus = AppShellBus(
        onNavigate: navigated.add,
        onUnhandled: unhandled.add,
      );
      bus.navigate('skworld://skcode/bogus');
      expect(navigated, isEmpty);
      expect(unhandled, ['skworld://skcode/bogus']);
      bus.dispose();
    });
  });

  group('a skworld://skcode/... link actually routes through a real GoRouter',
      () {
    late GoRouter router;
    late AppShellBus bus;

    setUp(() {
      router = GoRouter(
        initialLocation: AppRoutes.code,
        routes: [
          GoRoute(
            path: AppRoutes.code,
            builder: (_, _) => const _SpyScreen(label: 'landing'),
          ),
          GoRoute(
            path: AppRoutes.codeSession,
            builder: (_, state) =>
                _SpyScreen(label: 'session:${state.pathParameters['sid']}'),
          ),
          GoRoute(
            path: AppRoutes.codeDigest,
            builder: (_, _) => const _SpyScreen(label: 'digest'),
          ),
        ],
      );
      bus = AppShellBus(onNavigate: router.go);
    });

    tearDown(() => bus.dispose());

    testWidgets(
        'skworld://skcode/session/<sid> lands on the session screen for '
        'that exact sid', (tester) async {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(find.text('SPY:landing'), findsOneWidget);

      bus.navigate('skworld://skcode/session/s-42');
      await tester.pumpAndSettle();

      expect(find.text('SPY:session:s-42'), findsOneWidget);
    });

    testWidgets('skworld://skcode/digest lands on the digest screen',
        (tester) async {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      bus.navigate('skworld://skcode/digest');
      await tester.pumpAndSettle();

      expect(find.text('SPY:digest'), findsOneWidget);
    });
  });
}
