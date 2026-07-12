import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/app_router.dart';
import '../../core/chat_text.dart';
import '../../core/theme/theme.dart';
import '../../models/conversation.dart';
import '../../services/daemon_service.dart';
import '../../services/skcomms_client.dart';
import '../../services/guest_group_service.dart';
import '../chats/chats_provider.dart';
import 'groups_provider.dart';

/// Data class representing a group member in the Flutter UI.
class GroupMemberInfo {
  const GroupMemberInfo({
    required this.identityUri,
    required this.displayName,
    this.role = MemberRole.member,
    this.participantType = ParticipantType.human,
    this.isOnline = false,
    this.soulColor,
  });

  final String identityUri;
  final String displayName;
  final MemberRole role;
  final ParticipantType participantType;
  final bool isOnline;
  final Color? soulColor;

  /// Parse a member from the daemon's JSON response.
  factory GroupMemberInfo.fromJson(Map<String, dynamic> json) {
    return GroupMemberInfo(
      identityUri: json['identity_uri'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      role: _parseRole(json['role'] as String?),
      participantType: _parseParticipantType(json['participant_type'] as String?),
      isOnline: json['is_online'] as bool? ?? false,
    );
  }

  static MemberRole _parseRole(String? role) {
    switch (role) {
      case 'admin':
        return MemberRole.admin;
      case 'observer':
        return MemberRole.observer;
      default:
        return MemberRole.member;
    }
  }

  static ParticipantType _parseParticipantType(String? type) {
    switch (type) {
      case 'agent':
        return ParticipantType.agent;
      case 'service':
        return ParticipantType.service;
      default:
        return ParticipantType.human;
    }
  }
}

enum MemberRole { admin, member, observer }

enum ParticipantType { human, agent, service }

/// Well-known agent names for soul-color lookup.
const _knownAgents = {'lumina', 'jarvis', 'opus', 'ava', 'ara'};

/// Provider for the members of a specific group.
/// Fetches from the SKComms daemon's group members endpoint.
final groupMembersProvider =
    FutureProvider.family<List<GroupMemberInfo>, String>((ref, groupId) async {
  final client = ref.read(skcommsClientProvider);
  final raw = await client.getGroupMembers(groupId);

  return raw.map((json) {
    final member = GroupMemberInfo.fromJson(json);
    // Derive soul color for well-known agents.
    final name = member.displayName.toLowerCase();
    Color? soul;
    if (name == 'lumina') {
      soul = SovereignColors.soulLumina;
    } else if (name == 'jarvis') {
      soul = SovereignColors.soulJarvis;
    } else if (name == 'chef') {
      soul = SovereignColors.soulChef;
    }
    return GroupMemberInfo(
      identityUri: member.identityUri,
      displayName: member.displayName,
      role: member.role,
      participantType: _knownAgents.contains(name)
          ? ParticipantType.agent
          : member.participantType,
      isOnline: member.isOnline,
      soulColor: soul,
    );
  }).toList();
});

/// Group info & member management screen.
/// Shows group details, member list, and controls for add/remove members.
class GroupInfoScreen extends ConsumerWidget {
  const GroupInfoScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider);
    final group = groups.cast<Conversation?>().firstWhere(
          (c) => c?.peerId == groupId,
          orElse: () => null,
        );
    final membersAsync = ref.watch(groupMembersProvider(groupId));
    final tt = Theme.of(context).textTheme;

    // Am I (the operator) an admin of this group? Only an admin sees the
    // destructive "Delete group" action; everyone else gets "Leave group".
    // The operator is admin when the group's admin member resolves to my local
    // identity (the creator always counts). Until members load we treat the
    // operator as a possible admin only after data arrives (conservative).
    final iAmAdmin = _isOperatorAdmin(ref, membersAsync.valueOrNull);

    if (group == null) {
      return Scaffold(
        backgroundColor: SovereignColors.surfaceBase,
        appBar: AppBar(backgroundColor: SovereignColors.surfaceBase),
        body: const Center(child: Text('Group not found')),
      );
    }

    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(context, ref, group, tt),
          SliverToBoxAdapter(child: _buildGroupHeader(group, tt)),
          SliverToBoxAdapter(
            child: _buildEncryptionBanner(tt),
          ),
          SliverToBoxAdapter(
            child: _buildSectionHeader('Members', group.memberCount, tt),
          ),
          membersAsync.when(
            data: (members) => _buildMemberList(context, ref, members, tt),
            loading: () => const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(
                    color: SovereignColors.soulLumina,
                  ),
                ),
              ),
            ),
            error: (_, __) => const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Failed to load members'),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildAddMemberButton(context, ref, tt)),
          SliverToBoxAdapter(
              child: _buildActions(context, ref, tt, isAdmin: iAmAdmin)),
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  SliverAppBar _buildSliverAppBar(
    BuildContext context,
    WidgetRef ref,
    Conversation group,
    TextTheme tt,
  ) {
    final soul = group.resolvedSoulColor;
    return SliverAppBar(
      backgroundColor: SovereignColors.surfaceBase,
      pinned: true,
      expandedHeight: 160,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                soul.withValues(alpha: 0.15),
                SovereignColors.surfaceBase,
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 50),
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: soul.withValues(alpha: 0.6), width: 3),
                    color: soul.withValues(alpha: 0.15),
                  ),
                  child: Icon(Icons.group_rounded, color: soul, size: 32),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.edit_rounded),
          tooltip: 'Edit group',
          onPressed: () => _showEditDialogWithRef(context, ref),
        ),
      ],
    );
  }

  Widget _buildGroupHeader(Conversation group, TextTheme tt) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          Text(
            group.displayName,
            style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '${group.memberCount} members',
            style: tt.bodyMedium?.copyWith(
              color: SovereignColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEncryptionBanner(TextTheme tt) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const EncryptBadge(size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'AES-256-GCM encrypted. Keys distributed via PGP.',
                style: tt.bodySmall?.copyWith(
                  color: SovereignColors.accentEncrypt,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, TextTheme tt) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Text(
            title,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: SovereignColors.textTertiary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: tt.labelSmall?.copyWith(
                color: SovereignColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  SliverList _buildMemberList(
    BuildContext context,
    WidgetRef ref,
    List<GroupMemberInfo> members,
    TextTheme tt,
  ) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final member = members[index];
          return _MemberTile(
            member: member,
            onRemove: member.role != MemberRole.admin
                ? () => _confirmRemoveMember(context, ref, member)
                : null,
            onChangeRole: member.role != MemberRole.admin
                ? () => _showRoleDialog(context, ref, member)
                : null,
          );
        },
        childCount: members.length,
      ),
    );
  }

  Widget _buildAddMemberButton(
    BuildContext context,
    WidgetRef ref,
    TextTheme tt,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: GlassCard(
        onTap: () => _showAddMemberDialog(context, ref),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: SovereignColors.soulLumina.withValues(alpha: 0.15),
              ),
              child: const Icon(
                Icons.person_add_rounded,
                color: SovereignColors.soulLumina,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Add member',
              style: tt.titleSmall?.copyWith(
                color: SovereignColors.soulLumina,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// True when the local operator is an admin of this group (so the destructive
  /// "Delete group" action is offered). The operator is admin when the group's
  /// admin member resolves to my local identity, the creator always does.
  /// Returns false until members have loaded (conservative: no delete shown).
  bool _isOperatorAdmin(WidgetRef ref, List<GroupMemberInfo>? members) {
    if (members == null || members.isEmpty) return false;
    final meRaw = ref.read(daemonServiceProvider).localIdentity ?? '';
    final me = normalizePeerKey(meRaw);
    for (final m in members) {
      if (m.role == MemberRole.admin &&
          normalizePeerKey(m.identityUri) == me) {
        return true;
      }
    }
    return false;
  }

  Widget _buildActions(
    BuildContext context,
    WidgetRef ref,
    TextTheme tt, {
    required bool isAdmin,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          GlassCard(
            onTap: () => _shareInviteLink(context, ref),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(
                  Icons.link_rounded,
                  color: SovereignColors.soulLumina,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(
                  'Invite via link / Share link',
                  style: tt.titleSmall?.copyWith(
                    color: SovereignColors.soulLumina,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Non-admins leave; admins (the creator) can delete the whole group.
          GlassCard(
            onTap: () => _confirmLeaveGroup(context, ref),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(
                  Icons.exit_to_app_rounded,
                  color: SovereignColors.accentDanger,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(
                  'Leave group',
                  style: tt.titleSmall?.copyWith(
                    color: SovereignColors.accentDanger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(height: 12),
            GlassCard(
              key: const Key('delete-group-action'),
              onTap: () => _confirmDeleteGroup(context, ref),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(
                    Icons.delete_forever_rounded,
                    color: SovereignColors.accentDanger,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Delete group',
                    style: tt.titleSmall?.copyWith(
                      color: SovereignColors.accentDanger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Mint a shareable guest invite link for this group and show it to copy.
  ///
  /// Calls POST /api/v1/groups/{id}/invite (operator-gated server-side). When
  /// the guest-links feature is disabled on the server the call 404s, surfaced
  /// here as a friendly "guests are disabled" message.
  Future<void> _shareInviteLink(BuildContext context, WidgetRef ref) async {
    final svc = ref.read(guestInviteServiceProvider);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: SovereignColors.soulLumina),
      ),
    );
    String? link;
    String? error;
    try {
      final res = await svc.createInvite(groupId: groupId);
      final joinUrl = (res['join_url'] as String?) ?? '';
      if (joinUrl.isEmpty) {
        error = 'The server did not return an invite link.';
      } else {
        link = svc.fullLink(joinUrl);
      }
    } catch (e) {
      error = 'Could not create an invite link. Guest links may be disabled '
          'on this server.';
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner

    final tt = Theme.of(context).textTheme;
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Share invite link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (error != null)
              Text(error, style: tt.bodyMedium)
            else ...[
              Text(
                'Anyone with this link can join THIS room as an untrusted '
                'guest. They can chat, call, and share files here only.',
                style: tt.bodySmall
                    ?.copyWith(color: SovereignColors.textSecondary),
              ),
              const SizedBox(height: 12),
              SelectableText(
                link ?? '',
                style: tt.bodySmall
                    ?.copyWith(color: SovereignColors.soulLumina),
              ),
            ],
          ],
        ),
        actions: [
          if (link != null)
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link!));
                if (dctx.mounted) Navigator.of(dctx).pop();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invite link copied')),
                  );
                }
              },
            ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────

  void _showEditDialogWithRef(BuildContext context, WidgetRef ref) {
    final groups = ref.read(groupsProvider);
    final current = groups.cast<Conversation?>().firstWhere(
          (c) => c?.peerId == groupId,
          orElse: () => null,
        );

    final nameController =
        TextEditingController(text: current?.displayName ?? '');

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Edit Group'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Group name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = nameController.text.trim();
              if (newName.isEmpty) {
                Navigator.of(dialogCtx).pop();
                return;
              }
              Navigator.of(dialogCtx).pop();
              await _renameGroup(context, ref, newName);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showAddMemberDialog(BuildContext context, WidgetRef ref) {
    final chats = ref.read(chatsProvider);
    // Filter to non-group conversations as potential members.
    final peers = chats.where((c) => !c.isGroup).toList();

    final selected = <String>{};

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // allow a tall, scrollable sheet
      backgroundColor: SovereignColors.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final maxH = MediaQuery.of(sheetContext).size.height * 0.8;
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 10, bottom: 6),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: SovereignColors.textTertiary
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Text(
                        'Add members',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                    ),
                    if (peers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('No peers discovered yet.'),
                      )
                    else
                      // Scrollable so you can reach every peer, not just the
                      // top few that fit.
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: peers.length,
                          itemBuilder: (_, i) {
                            final peer = peers[i];
                            final isSel = selected.contains(peer.peerId);
                            return ListTile(
                              leading: SoulAvatar(
                                soulColor: peer.resolvedSoulColor,
                                initials: peer.resolvedInitials,
                                isAgent: peer.isAgent,
                                isOnline: peer.isOnline,
                                size: 40,
                              ),
                              title: Text(peer.displayName),
                              subtitle: Text(
                                peer.isAgent ? 'Agent' : 'Human',
                                style: TextStyle(
                                  color: SovereignColors.textTertiary,
                                  fontSize: 12,
                                ),
                              ),
                              trailing: Icon(
                                isSel
                                    ? Icons.check_circle_rounded
                                    : Icons.circle_outlined,
                                color: isSel
                                    ? SovereignColors.soulLumina
                                    : SovereignColors.textTertiary,
                              ),
                              onTap: () => setSheet(() {
                                if (isSel) {
                                  selected.remove(peer.peerId);
                                } else {
                                  selected.add(peer.peerId);
                                }
                              }),
                            );
                          },
                        ),
                      ),
                    // The confirm ("go") button, adds everyone selected.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () {
                                  final chosen = peers
                                      .where((p) => selected.contains(p.peerId))
                                      .toList();
                                  Navigator.of(sheetContext).pop();
                                  for (final p in chosen) {
                                    _addMember(context, ref, p);
                                  }
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: SovereignColors.soulLumina,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            selected.isEmpty
                                ? 'Select members to add'
                                : 'Add ${selected.length} '
                                    'member${selected.length == 1 ? '' : 's'}',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addMember(
    BuildContext context,
    WidgetRef ref,
    Conversation peer,
  ) async {
    final client = ref.read(skcommsClientProvider);
    final notifier = ref.read(groupsProvider.notifier);

    try {
      await client.addGroupMember(groupId, identity: peer.peerId);
    } on Object {
      // Daemon offline, proceed locally so UX isn't blocked.
    }

    // Update local member count and refresh member list.
    final groups = ref.read(groupsProvider);
    final group = groups.firstWhere((c) => c.peerId == groupId);
    await notifier.updateGroup(
      group.copyWith(memberCount: group.memberCount + 1),
    );
    ref.invalidate(groupMembersProvider(groupId));

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${peer.displayName} added to group')),
      );
    }
  }

  void _confirmRemoveMember(
    BuildContext context,
    WidgetRef ref,
    GroupMemberInfo member,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Remove member'),
        content: Text(
          'Remove ${member.displayName} from this group? '
          'The group key will be rotated automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _removeMember(context, ref, member);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeMember(
    BuildContext context,
    WidgetRef ref,
    GroupMemberInfo member,
  ) async {
    final client = ref.read(skcommsClientProvider);
    final notifier = ref.read(groupsProvider.notifier);

    try {
      await client.removeGroupMember(groupId, member.identityUri);
    } on Object {
      // Daemon offline, proceed locally.
    }

    final groups = ref.read(groupsProvider);
    final group = groups.firstWhere((c) => c.peerId == groupId);
    await notifier.updateGroup(
      group.copyWith(
        memberCount: (group.memberCount - 1).clamp(1, 999),
      ),
    );
    ref.invalidate(groupMembersProvider(groupId));

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${member.displayName} removed. Key rotated.'),
        ),
      );
    }
  }

  Future<void> _renameGroup(
    BuildContext context,
    WidgetRef ref,
    String newName,
  ) async {
    final client = ref.read(skcommsClientProvider);
    final notifier = ref.read(groupsProvider.notifier);

    try {
      await client.updateGroupInfo(groupId, name: newName);
    } on Object {
      // Daemon offline, update locally.
    }

    final groups = ref.read(groupsProvider);
    final group = groups.firstWhere((c) => c.peerId == groupId);
    await notifier.updateGroup(group.copyWith(displayName: newName));

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name updated')),
      );
    }
  }

  void _showRoleDialog(
    BuildContext context,
    WidgetRef ref,
    GroupMemberInfo member,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: Text('Role: ${member.displayName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final role in MemberRole.values)
              RadioListTile<MemberRole>(
                title: Text(_roleLabel(role)),
                subtitle: Text(
                  _roleDescription(role),
                  style: const TextStyle(fontSize: 12),
                ),
                value: role,
                groupValue: member.role,
                onChanged: (value) async {
                  Navigator.of(dialogContext).pop();
                  final roleName = value!.name; // 'admin', 'member', 'observer'
                  final client = ref.read(skcommsClientProvider);
                  try {
                    await client.addGroupMember(
                      groupId,
                      identity: member.identityUri,
                      role: roleName,
                    );
                  } on Object {
                    // Daemon offline, show optimistic feedback.
                  }
                  ref.invalidate(groupMembersProvider(groupId));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${member.displayName} is now ${_roleLabel(value)}',
                        ),
                      ),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void _confirmLeaveGroup(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Leave group'),
        content: const Text(
          'You will no longer receive messages from this group. '
          'Your group key will be revoked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final client = ref.read(skcommsClientProvider);
              try {
                await client.leaveGroup(groupId);
              } on Object {
                // Daemon offline, remove locally.
              }
              await ref.read(groupsProvider.notifier).removeGroup(groupId);
              if (context.mounted) context.go('/groups');
            },
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  /// Admin-only: delete the WHOLE group. Confirms, calls DELETE
  /// /api/v1/groups/{id} (server re-enforces the admin gate → 403 otherwise),
  /// removes it from the local Groups list, and navigates back to the Groups
  /// list. A 403 (not actually admin) surfaces a clear message and keeps the
  /// group.
  void _confirmDeleteGroup(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        title: const Text('Delete group'),
        content: const Text(
          'This permanently deletes the group for everyone and removes its '
          'message thread. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('delete-group-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final client = ref.read(skcommsClientProvider);
              final messenger = ScaffoldMessenger.of(context);
              bool deletedServerSide = true;
              String? errorMsg;
              try {
                await client.deleteGroup(groupId);
              } on Object catch (e) {
                deletedServerSide = false;
                // A 403 means we are not actually an admin, keep the group.
                final s = e.toString();
                if (s.contains('403')) {
                  errorMsg = 'Only an admin can delete this group.';
                }
              }
              if (errorMsg != null) {
                messenger.showSnackBar(SnackBar(content: Text(errorMsg)));
                return;
              }
              // Remove from the local list (covers the daemon-offline path too)
              // and return to the Groups list with a working back path.
              await ref.read(groupsProvider.notifier).removeGroup(groupId);
              if (!deletedServerSide) {
                messenger.showSnackBar(const SnackBar(
                  content: Text('Removed locally (daemon offline).'),
                ));
              }
              if (context.mounted) context.go(AppRoutes.groups);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _roleLabel(MemberRole role) {
    switch (role) {
      case MemberRole.admin:
        return 'Admin';
      case MemberRole.member:
        return 'Member';
      case MemberRole.observer:
        return 'Observer';
    }
  }

  String _roleDescription(MemberRole role) {
    switch (role) {
      case MemberRole.admin:
        return 'Can manage members and group settings';
      case MemberRole.member:
        return 'Can send messages and invoke tools';
      case MemberRole.observer:
        return 'Read-only access to group messages';
    }
  }
}

/// Tile widget for a single group member.
class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    this.onRemove,
    this.onChangeRole,
  });

  final GroupMemberInfo member;
  final VoidCallback? onRemove;
  final VoidCallback? onChangeRole;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final soul = member.soulColor ??
        SovereignColors.fromFingerprint(member.identityUri);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SoulAvatar(
              soulColor: soul,
              initials: member.displayName.isNotEmpty
                  ? member.displayName[0].toUpperCase()
                  : '?',
              isAgent: member.participantType == ParticipantType.agent,
              isOnline: member.isOnline,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.displayName,
                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _RoleBadge(role: member.role),
                      const SizedBox(width: 6),
                      if (member.participantType == ParticipantType.agent)
                        Text(
                          'Agent',
                          style: tt.labelSmall?.copyWith(
                            color: SovereignColors.textTertiary,
                            fontSize: 10,
                          ),
                        )
                      else
                        Text(
                          'Human',
                          style: tt.labelSmall?.copyWith(
                            color: SovereignColors.textTertiary,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (onChangeRole != null || onRemove != null)
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: SovereignColors.textTertiary,
                  size: 18,
                ),
                color: SovereignColors.surfaceRaised,
                onSelected: (value) {
                  if (value == 'role') onChangeRole?.call();
                  if (value == 'remove') onRemove?.call();
                },
                itemBuilder: (_) => [
                  if (onChangeRole != null)
                    const PopupMenuItem(
                      value: 'role',
                      child: Row(
                        children: [
                          Icon(Icons.swap_horiz_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Change role'),
                        ],
                      ),
                    ),
                  if (onRemove != null)
                    PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          Icon(
                            Icons.person_remove_rounded,
                            size: 18,
                            color: SovereignColors.accentDanger,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Remove',
                            style: TextStyle(
                              color: SovereignColors.accentDanger,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Small role badge (admin/member/observer).
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final MemberRole role;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (role) {
      MemberRole.admin => ('Admin', SovereignColors.soulChef),
      MemberRole.member => ('Member', SovereignColors.soulJarvis),
      MemberRole.observer => ('Observer', SovereignColors.textTertiary),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
