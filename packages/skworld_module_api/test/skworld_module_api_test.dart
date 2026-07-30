import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

// --- Minimal fakes proving the contract types instantiate and compose. ------

class _FakeAuth implements AuthContext {
  @override
  String get audience => 'skchat';

  @override
  String? get subjectFqid => 'agent:lumina@skworld.io';

  @override
  Set<String> get scopes => const {'chat.read', 'chat.send'};

  @override
  bool hasScope(String scope) => scopes.contains(scope);

  @override
  Future<String?> token() async => 'audience-scoped-token';
}

class _FakeBus implements ShellBus {
  final _controller = StreamController<ShellEvent>.broadcast();
  final navigations = <String>[];
  final emitted = <ShellEvent>[];

  @override
  void navigate(String deeplink) => navigations.add(deeplink);

  @override
  void emit(ShellEvent event) {
    emitted.add(event);
    _controller.add(event);
  }

  @override
  Stream<ShellEvent> get events => _controller.stream;
}

class _FakeShell implements ShellContext {
  _FakeShell(this.auth, this.bus);

  @override
  final AuthContext auth;

  @override
  final ShellBus bus;

  @override
  ThemeData get theme => ThemeData();
}

/// A module that works in BOTH modes: mounted (`shell != null`) and standalone
/// (`shell == null`). This is the whole point of the nullable boundary.
class _FakeModule implements SkworldModule {
  @override
  String get id => 'skchat';

  @override
  ModuleNav get nav => const ModuleNav(
        label: 'Chats',
        icon: IconData(0xe0b7, fontFamily: 'MaterialIcons'),
        order: 20,
        deeplinkPrefix: 'skworld://skchat/',
      );

  @override
  Widget build(BuildContext context, ShellContext? shell) {
    // The standalone signal: shell == null means run our own chrome.
    final mounted = shell != null;
    return Text(
      mounted ? 'mounted' : 'standalone',
      textDirection: TextDirection.ltr,
    );
  }
}

void main() {
  test('contract types instantiate and compose', () {
    final auth = _FakeAuth();
    final bus = _FakeBus();
    final ShellContext shell = _FakeShell(auth, bus);

    expect(shell.auth.audience, 'skchat');
    expect(shell.auth.hasScope('chat.send'), isTrue);
    expect(shell.auth.hasScope('calls.join'), isFalse);
    expect(shell.theme, isA<ThemeData>());

    shell.bus.navigate('skworld://skchat/thread/abc');
    shell.bus.emit(const ShellEvent('unreadChanged', data: {'count': 3}));
    expect(bus.navigations, ['skworld://skchat/thread/abc']);
    expect(bus.emitted.single.name, 'unreadChanged');
    expect(bus.emitted.single.data['count'], 3);
  });

  test('async audience-scoped token resolves', () async {
    expect(await _FakeAuth().token(), 'audience-scoped-token');
  });

  testWidgets('module renders mounted with a non-null ShellContext',
      (tester) async {
    final ShellContext shell = _FakeShell(_FakeAuth(), _FakeBus());
    final module = _FakeModule();

    await tester.pumpWidget(
      Builder(builder: (context) => module.build(context, shell)),
    );

    expect(find.text('mounted'), findsOneWidget);
    expect(find.text('standalone'), findsNothing);
  });

  testWidgets('module renders standalone when ShellContext is null',
      (tester) async {
    final module = _FakeModule();

    // ShellContext? nullability compiles and drives the standalone path.
    const ShellContext? noShell = null;
    await tester.pumpWidget(
      Builder(builder: (context) => module.build(context, noShell)),
    );

    expect(find.text('standalone'), findsOneWidget);
    expect(find.text('mounted'), findsNothing);
  });

  test('nav metadata carries the manifest-shaped fields', () {
    final module = _FakeModule();
    expect(module.id, 'skchat');
    expect(module.nav.label, 'Chats');
    expect(module.nav.order, 20);
    expect(module.nav.deeplinkPrefix, 'skworld://skchat/');
    expect(module.nav.copyWith(order: 5).order, 5);
  });
}
