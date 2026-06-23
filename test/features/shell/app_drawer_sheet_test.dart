import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skchat/core/modules/module_registry.dart';
import 'package:skchat/features/shell/app_drawer_sheet.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/module_prefs.dart';

NodeCapabilities _caps({String geoStatus = 'up'}) {
  return NodeCapabilities.fromJson({
    'node': {'id': 'n'},
    'services': [
      {'id': 'text', 'status': 'up'},
      {'id': 'voice', 'status': 'up'},
      {'id': 'geo-cot', 'status': geoStatus},
      {'id': 'access-plane', 'status': 'up'},
    ],
    'transports': const [],
  });
}

class _StubPrefs extends ModulePrefsNotifier {
  _StubPrefs(this._initial);
  final ModulePrefs _initial;
  @override
  ModulePrefs build() => _initial;
}

ModulePrefs _allEnabled() => ModulePrefs(
      enabledIds: {for (final m in kBuiltinModules) m.id},
      initialized: true,
    );

Widget _wrap(NodeCapabilities caps, ModulePrefs prefs) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: AppDrawerSheet()),
      ),
      GoRoute(path: '/skmap', builder: (_, _) => const Scaffold()),
    ],
  );
  return ProviderScope(
    overrides: [
      nodeCapabilitiesProvider.overrideWith((ref) async => caps),
      modulePrefsProvider.overrideWith(() => _StubPrefs(prefs)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('drawer renders enabled drawer-slot modules incl. skmap',
      (tester) async {
    await tester.pumpWidget(_wrap(_caps(), _allEnabled()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('drawer-module-skmap')), findsOneWidget);
    expect(find.text('SkMap'), findsOneWidget);
    // chats is a nav-default module → NOT in the drawer.
    expect(find.byKey(const Key('drawer-module-chats')), findsNothing);
  });

  testWidgets('skmap greys (lock icon) in drawer when geo-cot is down',
      (tester) async {
    await tester.pumpWidget(_wrap(_caps(geoStatus: 'down'), _allEnabled()));
    await tester.pumpAndSettle();

    final tile = find.byKey(const Key('drawer-module-skmap'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(
          of: tile, matching: find.byIcon(Icons.lock_outline_rounded)),
      findsOneWidget,
    );
  });

  testWidgets('disabling skmap removes it from the drawer', (tester) async {
    final prefs = ModulePrefs(
      enabledIds: {for (final m in kBuiltinModules) m.id}..remove('skmap'),
      initialized: true,
    );
    await tester.pumpWidget(_wrap(_caps(), prefs));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drawer-module-skmap')), findsNothing);
  });
}
