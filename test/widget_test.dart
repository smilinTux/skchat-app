import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skchat/data/conversation_repository.dart';
import 'package:skchat/data/message_repository.dart';
import 'package:skchat/main.dart';
import 'package:skchat/models/conversation.dart';
import 'package:skchat/services/skcomms_client.dart';
import 'package:skchat/services/skcomms_sync.dart';
import 'package:skchat/services/capabilities_service.dart';
import 'package:skchat/services/module_prefs.dart';

class MockSKCommsClient extends Mock implements SKCommsClient {}

class MockConversationRepository extends Mock
    implements ConversationRepository {}

class MockMessageRepository extends Mock implements MessageRepository {}

void main() {
  testWidgets('SKChatApp smoke test', (WidgetTester tester) async {
    final mockClient = MockSKCommsClient();
    final mockConvoRepo = MockConversationRepository();
    final mockMsgRepo = MockMessageRepository();

    when(() => mockClient.isAlive()).thenAnswer((_) async => false);
    when(() => mockClient.getInbox()).thenAnswer((_) async => []);
    when(() => mockConvoRepo.getAll()).thenAnswer((_) async => <Conversation>[]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          skcommsClientProvider.overrideWithValue(mockClient),
          skcommsSyncProvider.overrideWith(() => _NoOpSyncNotifier()),
          conversationRepositoryProvider.overrideWithValue(mockConvoRepo),
          messageRepositoryProvider.overrideWithValue(mockMsgRepo),
          // Module spine: resolve capabilities to null (offline) and seed
          // prefs in-memory so the new chats-AppBar module chain doesn't
          // open Hive / fire a network-timeout timer during the smoke test.
          nodeCapabilitiesProvider.overrideWith((ref) async => null),
          modulePrefsProvider.overrideWith(_StubModulePrefs.new),
        ],
        child: const SKChatApp(),
      ),
    );
    await tester.pump();
    // App renders without crashing.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

/// A module-prefs notifier seeded in-memory (no Hive) for tests.
class _StubModulePrefs extends ModulePrefsNotifier {
  @override
  ModulePrefs build() => const ModulePrefs(initialized: true);
}

/// A no-op sync notifier that skips timer creation for tests.
class _NoOpSyncNotifier extends SKCommsSyncNotifier {
  @override
  DaemonState build() => const DaemonState(status: DaemonStatus.offline);
}
