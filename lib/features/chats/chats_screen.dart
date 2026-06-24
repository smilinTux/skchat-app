import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../shell/toolbar_module_actions.dart';
import 'chats_provider.dart';
import 'widgets/conversation_tile.dart';

/// Chat list screen — shows all conversations sorted by recency.
/// Each row is a GlassCard with soul-color avatar, encryption badge,
/// last message preview, and delivery status.
class ChatsScreen extends ConsumerWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(chatsProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: _buildAppBar(context, tt),
      body: conversations.isEmpty
          ? _buildEmpty(context, tt)
          : _buildList(conversations, context),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showComposeMenu(context),
        tooltip: 'New',
        child: const Icon(Icons.edit_rounded),
      ),
    );
  }

  /// Compose menu: start a 1:1 message OR create a new group. (Create-group was
  /// previously unreachable — the only entry points went to the peer picker.)
  void _showComposeMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded,
                  color: SovereignColors.textSecondary),
              title: const Text('New message',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.push(AppRoutes.peerPicker);
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add_rounded,
                  color: SovereignColors.textSecondary),
              title: const Text('New group',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              subtitle: const Text('Pick members + name it',
                  style: TextStyle(
                      color: SovereignColors.textTertiary, fontSize: 12)),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.push(AppRoutes.createGroup);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, TextTheme tt) {
    return AppBar(
      backgroundColor: SovereignColors.surfaceBase,
      title: Text('SKChat', style: tt.displayLarge?.copyWith(fontSize: 24)),
      actions: [
        const ToolbarModuleActions(),
        // Direct, discoverable entry to the dedicated Groups list/section
        // (the operator couldn't find a way to their groups — they were only
        // mixed into the Chats list). Reachable from the primary screen.
        IconButton(
          key: const Key('chats-open-groups'),
          icon: const Icon(Icons.groups_rounded),
          tooltip: 'Groups',
          onPressed: () => context.push(AppRoutes.groups),
        ),
        IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: 'Search',
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'New message or group',
          onPressed: () => _showComposeMenu(context),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildList(
    List conversations,
    BuildContext context,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 100),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conv = conversations[index];
        return ConversationTile(
          conversation: conv,
          onTap: () => context.push(AppRoutes.conversationPath(conv.peerId)),
        );
      },
    );
  }

  Widget _buildEmpty(BuildContext context, TextTheme tt) {
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
            style: tt.bodyMedium?.copyWith(
              color: SovereignColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
