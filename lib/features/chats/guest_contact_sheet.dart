import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/guest_dm_contacts_service.dart';

/// Open the operator's contact-management sheet for a single guest DM
/// (guest-dm C4): rename the private alias, set/clear expiry, mute (stops the
/// call ring, S6), and Revoke access. [onChanged] fires after any mutation so
/// the caller can refresh the S4-backed list/tile.
///
/// [groupId] is the guest-dm G7 addition: pass it when opening the sheet from
/// a gdm roster member row (never from a 1:1 guest DM) and the sheet offers a
/// second, less severe action - "Remove from this group" - alongside the
/// person-level Revoke access, and labels alias/mute as person-level so the
/// operator does not mistake either for a per-room setting.
/// [groupMembershipRevoked] lets the caller pre-disable that action when the
/// roster already shows this member's seat as revoked.
Future<void> showGuestContactSheet(
  BuildContext context, {
  required GuestContact contact,
  VoidCallback? onChanged,
  String? groupId,
  bool groupMembershipRevoked = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SovereignColors.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _GuestContactSheetBody(
      contact: contact,
      onChanged: onChanged,
      groupId: groupId,
      groupMembershipRevoked: groupMembershipRevoked,
    ),
  );
}

class _GuestContactSheetBody extends ConsumerStatefulWidget {
  const _GuestContactSheetBody({
    required this.contact,
    this.onChanged,
    this.groupId,
    this.groupMembershipRevoked = false,
  });

  final GuestContact contact;
  final VoidCallback? onChanged;

  /// Non-null when the sheet was opened from a gdm roster member row -
  /// enables the per-group "Remove from this group" action.
  final String? groupId;
  final bool groupMembershipRevoked;

  @override
  ConsumerState<_GuestContactSheetBody> createState() =>
      _GuestContactSheetBodyState();
}

class _GuestContactSheetBodyState
    extends ConsumerState<_GuestContactSheetBody> {
  late final TextEditingController _aliasCtl =
      TextEditingController(text: widget.contact.alias ?? '');
  late GuestContact _contact = widget.contact;
  late bool _groupMembershipRevoked = widget.groupMembershipRevoked;
  bool _busy = false;
  String? _error;

  GuestDmContactsService get _svc => ref.read(guestDmContactsServiceProvider);

  @override
  void dispose() {
    _aliasCtl.dispose();
    super.dispose();
  }

  String _errorFor(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        return 'Managing guest contacts is operator-only and not available on '
            'this account.';
      }
    }
    return 'That did not go through. Please try again.';
  }

  Future<void> _run(Future<void> Function() action, {bool close = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      widget.onChanged?.call();
      if (!mounted) return;
      if (close) {
        Navigator.of(context).maybePop();
      } else {
        setState(() => _busy = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errorFor(e);
      });
    }
  }

  Future<void> _saveAlias() => _run(() async {
        await _svc.updateContact(_contact.fp, alias: _aliasCtl.text.trim());
        _contact = _contact.copyWith(alias: _aliasCtl.text.trim());
      });

  Future<void> _setExpiry(int days) => _run(() async {
        await _svc.updateContact(_contact.fp, contactTtl: days * 86400);
      });

  Future<void> _clearExpiry() => _run(() async {
        // contact_ttl 0 => expires immediately is NOT the intent; clearing is
        // "no expiry". The server treats a huge TTL as effectively never.
        await _svc.updateContact(_contact.fp, contactTtl: 3650 * 86400);
        _contact = _contact.copyWith(clearExpiry: true);
      });

  Future<void> _toggleMute(bool v) => _run(() async {
        await _svc.updateContact(_contact.fp, muted: v);
        _contact = _contact.copyWith(muted: v);
      });

  Future<void> _revoke() async {
    // Opened from a group roster: this button is the person-level, EVERYTHING
    // action, so the copy must say so plainly - "Remove from this group"
    // below is the scoped one, and an operator must not be able to confuse
    // the two. Opened from a 1:1 guest DM (no group context): unchanged.
    final inGroup = widget.groupId != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Revoke access?'),
        content: Text(
          inGroup
              ? '${_contact.title} will lose access to every conversation '
                  'with you, not just this group, and the invite link will '
                  'stop working. This cannot be undone from here.'
              : '${_contact.title} will lose access to this chat and the '
                  'invite link will stop working. This cannot be undone '
                  'from here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.accentDanger),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _run(() => _svc.revoke(_contact.fp), close: true);
    }
  }

  /// guest-dm G7: per-group revoke, offered only when the sheet was opened
  /// from a gdm roster member ([widget.groupId] non-null). Deliberately
  /// worded against [_revoke]'s dialog above so the two cannot be confused:
  /// this one names the ONE group and says other conversations survive; that
  /// one says every conversation ends.
  Future<void> _removeFromGroup() async {
    final groupId = widget.groupId;
    if (groupId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Remove from this group?'),
        content: Text(
          '${_contact.title} will lose their seat in this group only. Any '
          'other conversations you have with this person keep working. This '
          'cannot be undone from here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.accentWarning),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _run(
        () => _svc.revokeGroupMembership(_contact.fp, groupId),
        close: true,
      );
      _groupMembershipRevoked = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _handle(),
            Row(
              children: [
                const Icon(Icons.manage_accounts_outlined,
                    color: SovereignColors.soulLumina, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_contact.title,
                      style: tt.titleMedium, overflow: TextOverflow.ellipsis),
                ),
                if (_contact.isRevoked)
                  const Text('Revoked',
                      style: TextStyle(
                          color: SovereignColors.textTertiary, fontSize: 12)),
              ],
            ),
            if (widget.groupId != null) ...[
              const SizedBox(height: 6),
              Text(
                'Alias and mute apply to this person everywhere, not just '
                'this group.',
                style: tt.bodySmall?.copyWith(
                    color: SovereignColors.textTertiary),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _aliasCtl,
              enabled: !_busy,
              style: const TextStyle(color: SovereignColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Private alias',
                helperText: 'Only you see this. Names this guest in your list.',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Save alias',
                  onPressed: _busy ? null : _saveAlias,
                ),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule,
                  color: SovereignColors.textSecondary),
              title: const Text('Access expiry',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              subtitle: Text(
                _contact.contactExpiresAt == null
                    ? 'No expiry set'
                    : 'Expires set',
                style: const TextStyle(
                    color: SovereignColors.textTertiary, fontSize: 12),
              ),
              trailing: PopupMenuButton<int>(
                enabled: !_busy,
                icon: const Icon(Icons.edit_calendar_outlined),
                onSelected: (v) => v == 0 ? _clearExpiry() : _setExpiry(v),
                itemBuilder: (_) => const [
                  PopupMenuItem<int>(value: 1, child: Text('In 1 day')),
                  PopupMenuItem<int>(value: 7, child: Text('In 7 days')),
                  PopupMenuItem<int>(value: 30, child: Text('In 30 days')),
                  PopupMenuItem<int>(value: 0, child: Text('No expiry')),
                ],
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _contact.muted,
              onChanged: _busy ? null : _toggleMute,
              activeThumbColor: SovereignColors.soulLumina,
              title: const Text('Mute',
                  style: TextStyle(color: SovereignColors.textPrimary)),
              subtitle: const Text('Stops this guest from ringing you',
                  style: TextStyle(
                      color: SovereignColors.textTertiary, fontSize: 12)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(
                      color: SovereignColors.accentDanger, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            // guest-dm G7: the scoped action lives above the person-level one
            // and uses warning (not danger) styling - it removes ONE seat,
            // not the whole relationship, so it must not read as equally
            // severe. Only offered when opened from a group roster member.
            if (widget.groupId != null) ...[
              OutlinedButton.icon(
                onPressed: _busy || _groupMembershipRevoked
                    ? null
                    : _removeFromGroup,
                icon: const Icon(Icons.group_remove_outlined,
                    color: SovereignColors.accentWarning),
                label: const Text('Remove from this group',
                    style: TextStyle(color: SovereignColors.accentWarning)),
              ),
              const SizedBox(height: 8),
            ],
            OutlinedButton.icon(
              onPressed: _busy || _contact.isRevoked ? null : _revoke,
              icon: const Icon(Icons.block, color: SovereignColors.accentDanger),
              label: const Text('Revoke access',
                  style: TextStyle(color: SovereignColors.accentDanger)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Container(
        margin: const EdgeInsets.only(top: 6, bottom: 10),
        alignment: Alignment.center,
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: SovereignColors.textTertiary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}
