import 'package:flutter/material.dart';
import 'package:skworld_module_api/skworld_module_api.dart';

import 'chat_text.dart';
import 'conversation_tile.dart';
import 'models/conversation.dart';
import 'models/peer_trust.dart';
import 'theme/glass_widgets.dart';
import 'theme/sovereign_colors.dart';
import 'theme/sovereign_theme.dart';

/// Resolves the injected trust view-model for a conversation row, or null for
/// no badge. The app supplies this (resolving the real `peer_trust_store` /
/// `group_trust` standing) so the package stays pure; omitted means no badges.
typedef ConversationTrustResolver = PeerTrust? Function(Conversation conversation);

/// Pure local filter over an injected conversation list (reconciled spec 3.2).
///
/// A blank or whitespace-only [query] returns [conversations] unchanged (empty
/// query shows all). Otherwise it matches the query case-insensitively against
/// each conversation's peer display name, its normalized peer key (via
/// [normalizePeerKey]), and its displayable preview text (via [displayTextFor],
/// so transport envelopes / control sentinels never leak into a match). No
/// matches yields an empty list, which the surface renders as its empty state.
///
/// This is deliberately a pure function over the ALREADY-injected list: search
/// introduces no new data source, it only narrows what the app already fed in.
List<Conversation> filterConversations(
  List<Conversation> conversations,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return conversations;
  return conversations.where((c) {
    final name = c.displayName.toLowerCase();
    final key = normalizePeerKey(c.peerId);
    final preview = (displayTextFor(c.lastMessage) ?? '').toLowerCase();
    return name.contains(q) || key.contains(q) || preview.contains(q);
  }).toList();
}

/// The body [SkchatModule.build] renders inside the shell (mounted) and under
/// the standalone runner (reconciled spec 3.2).
///
/// This is the REAL chats surface: it renders the extracted [Conversation] list
/// through [ConversationListTile] (soul-color avatars, E2E badge, previews,
/// delivery status, unread counts) on the extracted Sovereign Glass theme, and
/// now carries the two ChatsScreen-parity pieces the prior increments deferred:
///   * a COMPOSE FAB (Sovereign Glass styled) that, mounted, asks `shell.bus`
///     to navigate the module's `skworld://skchat/compose` deep link; standalone
///     (`shell == null`) it shows a local SnackBar (its own compose router lands
///     with the standalone runner), mirroring how row-tap navigation degrades.
///   * SEARCH, an AppBar action that filters the injected list LOCALLY via
///     [filterConversations] (empty query shows all, no matches shows the empty
///     state). No new data source: it only narrows the already-injected list.
///
/// It wires two shell surfaces for real:
///   * the THEME BRIDGE: mounted, it renders under `shell.theme`; standalone
///     (`shell == null`) it falls back to the extracted [SovereignTheme.dark].
///   * NAVIGATION: mounted, a tapped row (or the FAB) asks `shell.bus` to
///     navigate the module's `skworld://skchat/...` deep link; standalone it
///     shows a local SnackBar.
///
/// DATA: the live list still comes from the app's `chatsProvider` (Riverpod +
/// Hive + skcomms_client), which cannot move into this package yet without
/// dragging the whole service graph across the import gate. So the surface takes
/// an injected [conversations] list; when omitted it renders a small
/// representative sample so the real list UI is exercised in both modes, and an
/// explicitly empty list renders the empty state.
///
/// TRUST (the last deferred ChatsScreen-parity piece): trust badges and the
/// group composite avatar are now wired. The badge draws from a package-pure
/// [PeerTrust] view-model resolved app-side and injected via [trustResolver];
/// the group composite avatar renders whenever a row is a group. Both stay on
/// the pure side of the import gate: the real `peer_trust_store` / `group_trust`
/// standing is resolved in the app's `LiveChatsSurface` and handed in through
/// [trustResolver], never imported into this package. Omitting it (standalone /
/// unwired) simply renders no badges.
class ChatsSurface extends StatefulWidget {
  const ChatsSurface({
    super.key,
    this.shell,
    this.conversations,
    this.trustResolver,
  });

  /// The shell surfaces when mounted, or null in standalone mode.
  final ShellContext? shell;

  /// Injected conversations. Null renders a representative sample; an empty
  /// list renders the empty state; a populated list renders the real rows.
  final List<Conversation>? conversations;

  /// Resolves the trust badge for each row from app-injected data. Null (or a
  /// null result per row) renders no badge, so standalone / unwired mounts
  /// still render cleanly.
  final ConversationTrustResolver? trustResolver;

  @override
  State<ChatsSurface> createState() => _ChatsSurfaceState();
}

class _ChatsSurfaceState extends State<ChatsSurface> {
  final TextEditingController _searchCtl = TextEditingController();

  /// Whether the AppBar is in search mode (title swapped for a search field).
  bool _searching = false;

  /// The current search query. Empty shows all; non-empty filters locally.
  String _query = '';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() => setState(() {
        _searching = false;
        _query = '';
        _searchCtl.clear();
      });

  /// Compose: mounted, hand the compose deep link to the shell to route (the
  /// module's own `nav.deeplinkPrefix` authority, spec 3.1). Standalone, no
  /// compose router yet (lands with apps/skchat_standalone), so mirror row-tap
  /// and show a local SnackBar.
  void _onCompose(BuildContext context) {
    final bus = widget.shell?.bus;
    if (bus != null) {
      bus.navigate('skworld://skchat/compose');
      return;
    }
    // TODO(skchat-standalone): route compose through the standalone runner's
    // own router once it lands; for now degrade like row-tap navigation.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('New message')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mounted = widget.shell != null;
    // Theme bridge: the shell's theme when mounted, the extracted Sovereign
    // Glass theme when standalone.
    final theme = widget.shell?.theme ?? SovereignTheme.dark();
    final all = widget.conversations ?? _sampleConversations();
    final visible = filterConversations(all, _query);

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: SovereignColors.surfaceBase,
        appBar: AppBar(
          backgroundColor: SovereignColors.surfaceBase,
          title: _searching
              ? TextField(
                  controller: _searchCtl,
                  autofocus: true,
                  style: const TextStyle(color: SovereignColors.textPrimary),
                  cursorColor: SovereignColors.soulLumina,
                  decoration: const InputDecoration(
                    hintText: 'Search chats',
                    hintStyle:
                        TextStyle(color: SovereignColors.textSecondary),
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                )
              : const Text('Chats'),
          // Mounted, the shell already frames the module, so no back arrow.
          automaticallyImplyLeading: !mounted && !_searching,
          leading: _searching
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Close search',
                  onPressed: _closeSearch,
                )
              : null,
          actions: [
            if (_searching)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear search',
                onPressed: _closeSearch,
              )
            else
              IconButton(
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Search',
                onPressed: _openSearch,
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _onCompose(context),
          tooltip: 'New message',
          backgroundColor: SovereignColors.soulLumina,
          foregroundColor: SovereignColors.surfaceBase,
          child: const Icon(Icons.edit_rounded),
        ),
        body: all.isEmpty
            ? const _EmptyChats()
            : visible.isEmpty
                ? const _EmptyChats(
                    title: 'No matches',
                    subtitle: 'Try a different name or message.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final conv = visible[index];
                      return ConversationListTile(
                        conversation: conv,
                        trust: widget.trustResolver?.call(conv),
                        onTap: () => _openConversation(context, conv),
                      );
                    },
                  ),
      ),
    );
  }

  void _openConversation(BuildContext context, Conversation conv) {
    final bus = widget.shell?.bus;
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
  /// [ChatsSurface.conversations] once the service graph is extracted.
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
        members: const [
          ConversationMember(
            identityUri: 'agent:lumina@skworld.io',
            displayName: 'Lumina',
            soulFingerprint: 'lumina-fp',
          ),
          ConversationMember(
            identityUri: 'agent:jarvis@skworld.io',
            displayName: 'Jarvis',
            soulFingerprint: 'jarvis-fp',
          ),
          ConversationMember(
            identityUri: 'agent:chef@skworld.io',
            displayName: 'Chef',
            soulFingerprint: 'chef-fp',
          ),
        ],
      ),
    ];
  }
}

/// Empty state, mirrors the app ChatsScreen's empty view (glass encrypt badge
/// plus a prompt) without its router dependency. Reused for the no-search-match
/// case with a distinct title/subtitle.
class _EmptyChats extends StatelessWidget {
  const _EmptyChats({
    this.title = 'No conversations yet',
    this.subtitle = 'Start a new encrypted chat.',
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const EncryptBadge(size: 40),
          const SizedBox(height: 20),
          Text(title, style: tt.titleLarge),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: tt.bodyMedium
                ?.copyWith(color: SovereignColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
