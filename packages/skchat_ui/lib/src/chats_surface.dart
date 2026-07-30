import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'conversation_tile.dart';
import 'models/conversation.dart';
import 'theme/glass_widgets.dart';
import 'theme/sovereign_colors.dart';
import 'theme/sovereign_theme.dart';

/// The body [SkchatModule.build] renders inside the shell (mounted) and under
/// the standalone runner (reconciled spec 3.2).
///
/// This is now the REAL chats surface, not the earlier placeholder Scaffold: it
/// renders the extracted [Conversation] list through [ConversationListTile]
/// (soul-color avatars, E2E badge, previews, delivery status, unread counts) on
/// the extracted Sovereign Glass theme. It wires two shell surfaces for real:
///   * the THEME BRIDGE: mounted, it renders under `shell.theme`; standalone
///     (`shell == null`) it falls back to the extracted [SovereignTheme.dark].
///   * NAVIGATION: mounted, a tapped row asks `shell.bus` to navigate the
///     module's `skworld://skchat/thread/<peerId>` deep link; standalone it
///     shows a local SnackBar (its own router lands with the standalone runner).
///
/// DATA: the live list still comes from the app's `chatsProvider` (Riverpod +
/// Hive + skcomms_client), which cannot move into this package yet without
/// dragging the whole service graph across the import gate. So the surface takes
/// an injected [conversations] list; when omitted it renders a small
/// representative sample so the real list UI is exercised in both modes, and an
/// explicitly empty list renders the empty state.
///
/// TODO(skchat-ui-extraction): once `lib/services` (skcomms_client,
/// peer_trust_store), `lib/data` (conversation_repository) and the Riverpod
/// graph are extracted, feed the live `chatsProvider` list here and restore the
/// full ConsumerWidget tile (trust badges, group composite avatar), plus the
/// compose FAB and search that the app's `ChatsScreen` still owns.
class ChatsSurface extends StatelessWidget {
  const ChatsSurface({super.key, this.shell, this.conversations});

  /// The shell surfaces when mounted, or null in standalone mode.
  final ShellContext? shell;

  /// Injected conversations. Null renders a representative sample; an empty
  /// list renders the empty state; a populated list renders the real rows.
  final List<Conversation>? conversations;

  @override
  Widget build(BuildContext context) {
    final mounted = shell != null;
    // Theme bridge: the shell's theme when mounted, the extracted Sovereign
    // Glass theme when standalone.
    final theme = shell?.theme ?? SovereignTheme.dark();
    final convos = conversations ?? _sampleConversations();

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: SovereignColors.surfaceBase,
        appBar: AppBar(
          backgroundColor: SovereignColors.surfaceBase,
          title: const Text('Chats'),
          // Mounted, the shell already frames the module, so no back arrow.
          automaticallyImplyLeading: !mounted,
        ),
        body: convos.isEmpty
            ? _EmptyChats()
            : ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: convos.length,
                itemBuilder: (context, index) {
                  final conv = convos[index];
                  return ConversationListTile(
                    conversation: conv,
                    onTap: () => _openConversation(context, conv),
                  );
                },
              ),
      ),
    );
  }

  void _openConversation(BuildContext context, Conversation conv) {
    final bus = shell?.bus;
    if (bus != null) {
      // Mounted: hand the deep link back to the shell to route (the module's
      // own deeplink_prefix, spec 3.1).
      bus.navigate('skworld://skchat/thread/${conv.peerId}');
      return;
    }
    // Standalone: no shell router yet (lands with apps/skchat_standalone).
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Open ${conv.displayName}')),
    );
  }

  /// A small representative sample so the real list UI renders when no live
  /// list is injected. NOT wired to any daemon; the live `chatsProvider` feeds
  /// [conversations] once the service graph is extracted (see class TODO).
  static List<Conversation> _sampleConversations() {
    final now = DateTime.now();
    return [
      Conversation(
        peerId: 'lumina',
        displayName: 'Lumina',
        lastMessage: 'The fleet is green- all twenty services healthy.',
        lastMessageTime: now.subtract(const Duration(minutes: 2)),
        soulColor: SovereignColors.soulLumina,
        isAgent: true,
        isOnline: true,
        unreadCount: 2,
      ),
      Conversation(
        peerId: 'jarvis',
        displayName: 'Jarvis',
        lastMessage: 'Running the overnight build now.',
        lastMessageTime: now.subtract(const Duration(hours: 3)),
        soulColor: SovereignColors.soulJarvis,
        isAgent: true,
        lastDeliveryStatus: 'read',
      ),
      Conversation(
        peerId: 'skworld-ops',
        displayName: 'SKWorld Ops',
        lastMessage: 'Deploy window opens at 22:00.',
        lastMessageTime: now.subtract(const Duration(days: 1)),
        soulFingerprint: 'skworld-ops-group',
        isGroup: true,
        memberCount: 4,
      ),
    ];
  }
}

/// Empty state, mirrors the app ChatsScreen's empty view (glass encrypt badge
/// plus a prompt) without its router dependency.
class _EmptyChats extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const EncryptBadge(size: 40),
          const SizedBox(height: 20),
          Text('No conversations yet', style: tt.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Start a new encrypted chat.',
            style: tt.bodyMedium
                ?.copyWith(color: SovereignColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
