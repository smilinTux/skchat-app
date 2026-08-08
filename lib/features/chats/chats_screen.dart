import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme.dart';
import '../../models/conversation.dart';
import '../../services/guest_dm_contacts_service.dart';
import '../shell/toolbar_module_actions.dart';
import 'chats_provider.dart';
import 'guest_contact_sheet.dart';
import 'guest_group_mint_sheet.dart';
import 'invite_to_dm_sheet.dart';
import 'widgets/conversation_tile.dart';

/// Chat list screen, shows all conversations sorted by recency.
/// Each row is a GlassCard with soul-color avatar, encryption badge,
/// last message preview, and delivery status.
class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  /// guest-dm C3: the Guests filter (show only guest DMs), default off.
  bool _guestsOnly = false;

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(chatsProvider);
    final tt = Theme.of(context).textTheme;
    final hasGuestDms = conversations.any((c) => c.isGuestDm);
    final shown = _guestsOnly
        ? conversations.where((c) => c.isGuestDm).toList()
        : conversations;

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: _buildAppBar(context, tt),
      body: Column(
        children: [
          if (hasGuestDms)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: FilterChip(
                  label: const Text('Guests'),
                  avatar: const Icon(Icons.person_outline, size: 16),
                  selected: _guestsOnly,
                  onSelected: (v) => setState(() => _guestsOnly = v),
                ),
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? _buildEmpty(context, tt)
                : _buildList(shown, context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showComposeMenu(context),
        tooltip: 'New',
        child: const Icon(Icons.edit_rounded),
      ),
    );
  }

  /// Compose menu: start a 1:1 message OR create a new group. (Create-group was
  /// previously unreachable, the only entry points went to the peer picker.)
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
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_rounded,
                  color: SovereignColors.textSecondary),
              title: const Text('Invite to DM',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              subtitle: const Text('Link someone straight into a 1:1 with you',
                  style: TextStyle(
                      color: SovereignColors.textTertiary, fontSize: 12)),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showInviteToDmSheet(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.groups_2_outlined,
                  color: SovereignColors.textSecondary),
              title: const Text('New guest group',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              subtitle: const Text('Name it, then invite guests by link',
                  style: TextStyle(
                      color: SovereignColors.textTertiary, fontSize: 12)),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showNewGuestGroupFlow(context, ref);
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
    List<Conversation> conversations,
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
          // guest-dm C4/G7 gap-fill: long-press opens the C4 contact sheet,
          // but only for a real 1:1 guest DM. A gdm has several guests (no
          // single contact to manage - G7's per-member roster is the right
          // surface there), and an ordinary chat/group has no dm_contacts
          // row at all.
          onLongPress: conv.isGuestDm && !conv.isGdm
              ? () => _openGuestContactSheet(context, ref, conv)
              : null,
        );
      },
    );
  }

  /// guest-dm C4/G7 gap-fill: open the C4 sheet for a 1:1 guest DM row.
  ///
  /// Mirrors `_openGuestContactSheet` in group_info_screen.dart, but a 1:1
  /// conversation carries no per-member guest flag on its participants (that
  /// merge only happens server-side for a gdm, see `_guest_member_fields` in
  /// daemon_proxy_groups.py), so there is no local guest fp to derive the way
  /// G7's roster row can. What IS reliable: `group_to_conversation` emits
  /// `peer_id: group.id`, and the server resolves the S4 guest badge via
  /// `get_dm_contact_by_group(group.id)` - so this conversation's `peerId` IS
  /// the contact's `group_id`. Fetch the full S4 list and match on that to
  /// recover the real fp. No `groupId` is passed to the sheet: that parameter
  /// is what turns on G7's per-group "Remove from this group" action, which
  /// is meaningless for a 1:1.
  Future<void> _openGuestContactSheet(
    BuildContext context,
    WidgetRef ref,
    Conversation conversation,
  ) async {
    final svc = ref.read(guestDmContactsServiceProvider);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: SovereignColors.soulLumina),
      ),
    );
    GuestContact? contact;
    try {
      final all = await svc.listContacts();
      for (final c in all) {
        if (c.groupId == conversation.peerId) {
          contact = c;
          break;
        }
      }
    } on Object {
      // Daemon offline or the route is unavailable: contact stays null,
      // handled below. Unlike G7's roster row, there is no reliable
      // client-side fp fallback for a 1:1 (see the doc comment above), so a
      // failed lookup surfaces an error rather than opening a sheet with an
      // unusable identity.
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner

    if (contact == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              "Could not load this guest's contact info. Try again when online."),
        ),
      );
      return;
    }

    await showGuestContactSheet(
      context,
      contact: contact,
      // Revoke/rename change the guest badge fields (`guest_dm`/`guest_name`/
      // `guest_alias`/`muted`) carried on THIS conversation, so re-fetch the
      // list right away rather than waiting on the next poll - same idiom as
      // group_info_screen's `ref.invalidate(groupMembersProvider(groupId))`.
      onChanged: () => ref.read(chatsProvider.notifier).refresh(),
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
