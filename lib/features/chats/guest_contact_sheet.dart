import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/sovereign_colors.dart';
import '../../services/guest_dm_contacts_service.dart';

/// Open the operator's contact-management sheet for a single guest DM
/// (guest-dm C4): rename the private alias, set/clear expiry, mute (stops the
/// call ring, S6), and Revoke access. [onChanged] fires after any mutation so
/// the caller can refresh the S4-backed list/tile.
Future<void> showGuestContactSheet(
  BuildContext context, {
  required GuestContact contact,
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: SovereignColors.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _GuestContactSheetBody(contact: contact, onChanged: onChanged),
  );
}

class _GuestContactSheetBody extends ConsumerStatefulWidget {
  const _GuestContactSheetBody({required this.contact, this.onChanged});

  final GuestContact contact;
  final VoidCallback? onChanged;

  @override
  ConsumerState<_GuestContactSheetBody> createState() =>
      _GuestContactSheetBodyState();
}

class _GuestContactSheetBodyState
    extends ConsumerState<_GuestContactSheetBody> {
  late final TextEditingController _aliasCtl =
      TextEditingController(text: widget.contact.alias ?? '');
  late GuestContact _contact = widget.contact;
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Revoke access?'),
        content: Text(
          '${_contact.title} will lose access to this chat and the invite link '
          'will stop working. This cannot be undone from here.',
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
