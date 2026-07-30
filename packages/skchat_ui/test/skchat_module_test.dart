import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skworld_module_api/skworld_module_api.dart';
import 'package:skchat_ui/skchat_ui.dart';

// --- Minimal shell fakes so the mounted path has a non-null ShellContext. ----

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
  @override
  void navigate(String deeplink) {}
  @override
  void emit(ShellEvent event) {}
  @override
  Stream<ShellEvent> get events => const Stream.empty();
}

class _FakeShell implements ShellContext {
  @override
  AuthContext get auth => _FakeAuth();
  @override
  ShellBus get bus => _FakeBus();
  @override
  ThemeData get theme => ThemeData();
}

void main() {
  test('SkchatModule instantiates and is a SkworldModule', () {
    const module = SkchatModule();
    expect(module, isA<SkworldModule>());
  });

  test('nav metadata matches the skchat manifest block (spec 3.1)', () {
    const module = SkchatModule();
    expect(module.id, 'skchat');
    expect(module.nav.label, 'Chats');
    expect(module.nav.icon, Icons.chat);
    expect(module.nav.order, 20);
    expect(module.nav.deeplinkPrefix, 'skworld://skchat/');
  });

  testWidgets('build(null) returns a widget in standalone mode',
      (tester) async {
    const module = SkchatModule();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          // ShellContext? null == standalone signal.
          builder: (context) => module.build(context, null),
        ),
      ),
    );
    expect(find.byType(ChatsSurface), findsOneWidget);
    expect(find.text('skchat (standalone)'), findsOneWidget);
  });

  testWidgets('build(shell) returns a widget in mounted mode', (tester) async {
    const module = SkchatModule();
    final ShellContext shell = _FakeShell();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) => module.build(context, shell)),
      ),
    );
    expect(find.byType(ChatsSurface), findsOneWidget);
    expect(find.text('skchat (mounted in shell)'), findsOneWidget);
  });

  test('extracted leaf ChatMessage round-trips through JSON', () {
    final msg = ChatMessage(
      id: 'm1',
      peerId: 'p1',
      content: 'hello',
      timestamp: DateTime.parse('2026-07-30T00:00:00.000Z'),
      isOutbound: true,
    );
    final restored = ChatMessage.fromJson(msg.toJson());
    expect(restored.id, 'm1');
    expect(restored.content, 'hello');
    expect(restored.isOutbound, isTrue);
  });
}
