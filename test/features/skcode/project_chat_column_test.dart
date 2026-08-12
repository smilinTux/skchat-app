// Card C-12: ProjectChatColumn is the host-side half of skcode's
// project-chat injection seam (`SkcodeModule.projectChatBuilder`). Its own
// "Constraints" section requires an honest empty state when no group is
// bound for a repo -- today NOTHING creates a `meta.project`-tagged group
// (that machinery lives server-side, outside this Flutter repo), so this is
// the expected, permanent-until-that-ships state, proven here rather than
// left implicit.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/features/chats/chats_provider.dart';
import 'package:skchat/features/skcode/project_chat_column.dart';
import 'package:skchat/models/conversation.dart';

/// Overrides [chatsProvider] with a fixed list, entirely bypassing
/// [ChatsNotifier.build]'s real boot sequence (Hive + the skcomms daemon),
/// which this widget test has no business touching.
class _FixedChatsNotifier extends ChatsNotifier {
  _FixedChatsNotifier(this._fixed);
  final List<Conversation> _fixed;

  @override
  List<Conversation> build() => _fixed;
}

Conversation _conversation({required String peerId, String? metaProject}) {
  return Conversation(
    peerId: peerId,
    displayName: peerId,
    lastMessage: '',
    lastMessageTime: DateTime(2026),
    isGroup: true,
    metaProject: metaProject,
  );
}

void main() {
  testWidgets(
      'no group tagged meta.project for this repo renders the honest empty state, '
      'never a crash', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider.overrideWith(() => _FixedChatsNotifier([
                _conversation(peerId: 'g-unrelated', metaProject: 'repo:some-other-repo'),
              ])),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProjectChatColumn(repo: 'skworld-app')),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('skcodeNoProjectChatBound')), findsOneWidget);
    expect(find.textContaining('skworld-app'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty conversation list (no groups at all) also renders the empty state',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatsProvider.overrideWith(() => _FixedChatsNotifier(const [])),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProjectChatColumn(repo: 'skworld-app')),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('skcodeNoProjectChatBound')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
