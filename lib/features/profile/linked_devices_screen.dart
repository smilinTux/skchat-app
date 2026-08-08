import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../services/device_list_service.dart';

/// "Linked Devices" screen: every device enrolled to this operator identity
/// (`GET /api/v1/operator/devices`, via [DeviceListService.list]), with a
/// per-device Rename action, a per-device Unlink action, and a bulk "Unlink
/// all other devices" action.
///
/// THIS device (server-computed [LinkedDevice.isCurrent]) never renders an
/// Unlink control, that is a safety property, not decoration: the server
/// rejects a self-unlink with a 400
/// ([DeviceUnlinkFailureReason.selfUnlink]), so offering the action here
/// would put an affordance on screen for something that cannot succeed.
/// Renaming carries no such self-lockout risk, so it is offered on EVERY
/// row, including this device.
///
/// A device's [LinkedDevice.label] comes from one of three sources
/// (`operator_auth_routes.py`'s `_record_enrollment`, and
/// `device_routes.py:rename` for the third):
///  - `"client"`: the DEVICE named itself (the value R2 signs, see
///    `operator_session_service.dart:enroll`'s doc). Self-asserted and
///    therefore spoofable, e.g. a device could sign the label `Chef's
///    MacBook (verified)`.
///  - `"derived"`: the SERVER parsed a name from the enrolling request's
///    User-Agent (`_derive_label`). Not spoofable by the device, but not
///    reliable either: a browser cannot read its own machine's hostname, so
///    two different Linux desktops both surface as "Chrome on Linux" with no
///    way to tell them apart. That ambiguity is the entire reason renaming
///    exists.
///  - `"operator"`: the operator typed a real name via [DeviceListService.
///    rename] (`PATCH /api/v1/operator/devices/{fp}`). The one source that
///    is both accurate and confirmed by a human looking at the device.
///
/// Phase 3 (approval-to-link): [DeviceListService.listPending] surfaces every
/// device that enrolled with the shared operator token but has not been
/// approved by an already-approved device yet ([_PendingDevicesBanner]).
/// Such a device cannot mint a session and can do nothing else on its own,
/// so this is a security surface: an unrecognized row there is an intrusion
/// attempt, not a chore, and the banner is styled and worded accordingly.
///
/// Only `"operator"` is trusted. `"client"` and `"derived"` both render with
/// the SAME styling the rest of the app already uses for a self-asserted
/// guest name (see `guestDisplayTitle` / `ConversationMember.isUntrustedName`
/// in `packages/skchat_ui`, and the mirrored per-row style in
/// `group_info_screen.dart`): amber, italic. `"client"` additionally gets a
/// text-level `self-named:` marker (see [deviceRowTitle]) mirroring
/// `guestDisplayTitle`'s `guest:` prefix, so a self-asserted label cannot
/// visually pass as one the server assigned; `"derived"` gets the amber
/// italic styling only, since the device never claimed that name, the server
/// only guessed it. Renaming a device is what earns it the trusted
/// `"operator"` styling, that is the visible payoff for typing a real name.
class LinkedDevicesScreen extends ConsumerStatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  ConsumerState<LinkedDevicesScreen> createState() =>
      _LinkedDevicesScreenState();
}

enum _LoadState { loading, loaded, error }

class _LinkedDevicesScreenState extends ConsumerState<LinkedDevicesScreen> {
  _LoadState _state = _LoadState.loading;
  List<LinkedDevice> _devices = const [];
  List<LinkedDevice> _pending = const [];
  String _errorMessage = '';

  /// Fingerprints currently mid-unlink: their row shows a spinner instead of
  /// the Unlink button, so a slow request cannot be double-tapped.
  final Set<String> _busyFps = {};
  bool _busyAll = false;

  /// Fingerprints currently mid-rename: their row shows a spinner instead of
  /// the Rename button. Tracked separately from [_busyFps] since rename and
  /// unlink are different requests and a row should be able to show the
  /// right one is in flight.
  final Set<String> _renamingFps = {};

  /// Fingerprints currently mid-approve / mid-deny, tracked separately from
  /// each other (and from [_busyFps]/[_renamingFps]) for the same reason:
  /// each is its own request and a pending row should show the right one is
  /// in flight, not a generic spinner on both actions at once.
  final Set<String> _approvingFps = {};
  final Set<String> _denyingFps = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _LoadState.loading);
    try {
      final service = ref.read(deviceListServiceProvider);
      final devices = await service.list();
      final pending = await service.listPending();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _pending = pending;
        _state = _LoadState.loaded;
      });
    } catch (_) {
      // Never show a raw exception: daemon offline, network error, or a
      // malformed response all collapse to the same friendly retry state.
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not load linked devices. Check the daemon connection '
            'and try again.';
        _state = _LoadState.error;
      });
    }
  }

  String _rowLabel(LinkedDevice device) =>
      device.label.isNotEmpty ? device.label : device.deviceFp;

  /// Opens a dialog pre-filled with [device]'s current label, capped at 64
  /// characters to match the server's own cap. Empty input is rejected right
  /// here, before anything is sent, so a blank submit never round-trips to
  /// the server just to bounce off its 400.
  ///
  /// The dialog's [TextEditingController] is owned by [_RenameDialog], a
  /// StatefulWidget, rather than created and manually disposed here: a
  /// controller created in this method and disposed the instant `showDialog`
  /// resolves races the dialog's own exit-transition animation, which can
  /// still be building the TextField after the route has "finished"
  /// resolving. Letting the framework own the controller's lifecycle via
  /// `State.dispose()` disposes it only once the element is truly unmounted.
  Future<void> _confirmRename(LinkedDevice device) async {
    final newLabel = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(initialLabel: device.label),
    );
    if (newLabel == null) return;
    await _rename(device, newLabel);
  }

  Future<void> _rename(LinkedDevice device, String label) async {
    setState(() => _renamingFps.add(device.deviceFp));
    try {
      final updated =
          await ref.read(deviceListServiceProvider).rename(device.deviceFp, label);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Renamed to ${_rowLabel(updated)}')),
      );
      await _load();
    } on DeviceRenameException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyRenameMessage(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not rename this device. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _renamingFps.remove(device.deviceFp));
    }
  }

  /// Typed [DeviceRenameException] -> a short, friendly line, never the raw
  /// server `detail` string or a bare exception toString().
  String _friendlyRenameMessage(DeviceRenameException e) {
    switch (e.reason) {
      case DeviceRenameFailureReason.invalidLabel:
        return 'Enter a name for this device.';
      case DeviceRenameFailureReason.notFound:
        return 'That device is already gone.';
      case DeviceRenameFailureReason.unknown:
        return 'Could not rename this device. Try again.';
    }
  }

  Future<void> _confirmUnlink(LinkedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Unlink this device?'),
        content: Text(
          '"${_rowLabel(device)}" will no longer be able to obtain an '
          'operator session. This does not delete anything it already sent '
          'or received.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: SovereignColors.textTertiary),
            ),
          ),
          FilledButton(
            key: const Key('unlink-confirm-action'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _unlink(device);
  }

  Future<void> _unlink(LinkedDevice device) async {
    setState(() => _busyFps.add(device.deviceFp));
    try {
      await ref.read(deviceListServiceProvider).unlink(device.deviceFp);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unlinked ${_rowLabel(device)}')),
      );
      await _load();
    } on DeviceUnlinkException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyUnlinkMessage(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unlink this device. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyFps.remove(device.deviceFp));
    }
  }

  Future<void> _confirmUnlinkAllOthers() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Unlink all other devices?'),
        content: const Text(
          'Every device except this one will lose its operator session and '
          'have to be re-linked to use operator-gated features again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: SovereignColors.textTertiary),
            ),
          ),
          FilledButton(
            key: const Key('unlink-all-confirm-action'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: SovereignColors.accentDanger,
            ),
            child: const Text('Unlink all others'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _unlinkAllOthers();
  }

  Future<void> _unlinkAllOthers() async {
    setState(() => _busyAll = true);
    try {
      final result = await ref.read(deviceListServiceProvider).unlinkOthers();
      if (!mounted) return;
      final n = result.unlinked.length;
      final degradedNote =
          result.degraded.isNotEmpty ? ' (some incompletely)' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unlinked $n other device${n == 1 ? '' : 's'}$degradedNote',
          ),
        ),
      );
      await _load();
    } on DeviceUnlinkException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyUnlinkMessage(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unlink other devices. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyAll = false);
    }
  }

  /// Typed [DeviceUnlinkException] -> a short, friendly line, never the raw
  /// server `detail` string or a bare exception toString().
  String _friendlyUnlinkMessage(DeviceUnlinkException e) {
    switch (e.reason) {
      case DeviceUnlinkFailureReason.selfUnlink:
        return 'Cannot unlink the device you are using right now.';
      case DeviceUnlinkFailureReason.noOperatorSession:
        return 'You need an active operator session to manage devices.';
      case DeviceUnlinkFailureReason.notFound:
        return 'That device is already gone.';
      case DeviceUnlinkFailureReason.unknown:
        return 'Could not unlink this device. Try again.';
    }
  }

  /// Approve is the deliberate action: it always goes through a confirmation
  /// dialog naming the device, unlike [_deny], because approving is what
  /// hands a stranger an operator session. A pending device linked using the
  /// shared operator token; if the operator does not recognize it, that is
  /// an intrusion attempt, not a chore, so nothing here defaults to "yes".
  Future<void> _confirmApprove(LinkedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: SovereignColors.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Approve this device?'),
        content: Text(
          '"${_rowLabel(device)}" will be able to obtain an operator '
          'session and use every operator-gated feature. Only approve it '
          'if you recognize it as one of your own devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: SovereignColors.textTertiary),
            ),
          ),
          FilledButton(
            key: const Key('approve-confirm-action'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _approve(device);
  }

  Future<void> _approve(LinkedDevice device) async {
    setState(() => _approvingFps.add(device.deviceFp));
    try {
      await ref.read(deviceListServiceProvider).approve(device.deviceFp);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approved ${_rowLabel(device)}')),
      );
      await _load();
    } on DeviceApprovalException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyApprovalMessage(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not approve this device. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _approvingFps.remove(device.deviceFp));
    }
  }

  /// Typed [DeviceApprovalException] -> a short, friendly line, never the
  /// raw server `detail` string or a bare exception toString().
  String _friendlyApprovalMessage(DeviceApprovalException e) {
    switch (e.reason) {
      case DeviceApprovalFailureReason.noOperatorSession:
        return 'You need an active operator session to approve devices.';
      case DeviceApprovalFailureReason.notFound:
        return 'That device is already gone.';
      case DeviceApprovalFailureReason.unknown:
        return 'Could not approve this device. Try again.';
    }
  }

  /// Deny is deliberately NOT gated behind a confirmation dialog the way
  /// [_confirmApprove] is: rejecting a device nobody vouched for should be
  /// at least as easy to reach as approving it, not harder. It is a full
  /// unlink server-side, but there is nothing to lose by acting fast, the
  /// device never had a session to begin with.
  Future<void> _deny(LinkedDevice device) async {
    setState(() => _denyingFps.add(device.deviceFp));
    try {
      await ref.read(deviceListServiceProvider).deny(device.deviceFp);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Denied ${_rowLabel(device)}')),
      );
      await _load();
    } on DeviceDenyException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyDenyMessage(e))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not deny this device. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _denyingFps.remove(device.deviceFp));
    }
  }

  /// Typed [DeviceDenyException] -> a short, friendly line, never the raw
  /// server `detail` string or a bare exception toString().
  String _friendlyDenyMessage(DeviceDenyException e) {
    switch (e.reason) {
      case DeviceDenyFailureReason.selfDeny:
        return 'Cannot deny the device you are using right now.';
      case DeviceDenyFailureReason.noOperatorSession:
        return 'You need an active operator session to deny devices.';
      case DeviceDenyFailureReason.notFound:
        return 'That device is already gone.';
      case DeviceDenyFailureReason.unknown:
        return 'Could not deny this device. Try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: const Text('Linked Devices'),
      ),
      body: switch (_state) {
        _LoadState.loading => const Center(
            child:
                CircularProgressIndicator(color: SovereignColors.soulLumina),
          ),
        _LoadState.error => _ErrorView(message: _errorMessage, onRetry: _load),
        _LoadState.loaded => _buildLoaded(context),
      },
    );
  }

  Widget _buildLoaded(BuildContext context) {
    if (_devices.isEmpty && _pending.isEmpty) {
      return _EmptyView(onRefresh: _load);
    }
    final hasOthers = _devices.any((d) => !d.isCurrent);
    // `is_current` is computed server-side from the caller's operator
    // SESSION. A caller authenticating with only a shared X-Operator-Token
    // has no session, so the server marks no row current: every row then
    // shows an Unlink control (including the device in the operator's own
    // hand) and unlink-others appears, none of which can succeed (the server
    // 400s "no operator session"). Rather than let the operator discover
    // that by tapping, say so up front.
    final hasCurrent = _devices.any((d) => d.isCurrent);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_pending.isNotEmpty) ...[
            _PendingDevicesBanner(
              pending: _pending,
              approvingFps: _approvingFps,
              denyingFps: _denyingFps,
              onApprove: _confirmApprove,
              onDeny: _deny,
            ),
            const SizedBox(height: 12),
          ],
          if (!hasCurrent) ...[
            const _NoOperatorSessionBanner(),
            const SizedBox(height: 12),
          ],
          for (final device in _devices) ...[
            _DeviceRow(
              key: ValueKey(device.deviceFp),
              device: device,
              busy: _busyFps.contains(device.deviceFp),
              renaming: _renamingFps.contains(device.deviceFp),
              onUnlink: () => _confirmUnlink(device),
              onRename: () => _confirmRename(device),
            ),
            const SizedBox(height: 10),
          ],
          if (hasOthers) ...[
            const SizedBox(height: 8),
            _busyAll
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : OutlinedButton.icon(
                    key: const Key('unlink-all-others-action'),
                    onPressed: _confirmUnlinkAllOthers,
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Unlink all other devices'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: SovereignColors.accentDanger,
                      side:
                          const BorderSide(color: SovereignColors.accentDanger),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
          ],
        ],
      ),
    );
  }
}

// ── Device row ───────────────────────────────────────────────────────────

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    super.key,
    required this.device,
    required this.busy,
    required this.renaming,
    required this.onUnlink,
    required this.onRename,
  });

  final LinkedDevice device;
  final bool busy;
  final bool renaming;
  final VoidCallback onUnlink;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    // Anything short of an operator-confirmed rename renders untrusted (see
    // the class doc): "client" is spoofable by the device itself, "derived"
    // is merely the server's best guess from the User-Agent, right or wrong.
    // Only "operator" -- a human who typed the name after looking at the
    // device -- earns the trusted styling.
    final untrusted = device.labelSource != 'operator';
    final label = deviceRowTitle(device);
    final platformLabel = device.platform.isNotEmpty ? device.platform : 'unknown';

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(_platformIcon(device.platform), color: SovereignColors.textTertiary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: untrusted ? SovereignColors.accentWarning : null,
                          fontStyle:
                              untrusted ? FontStyle.italic : FontStyle.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (device.isCurrent) ...[
                      const SizedBox(width: 8),
                      const _ThisDeviceChip(),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$platformLabel · ${relativeLastSeen(device.lastSeen)}',
                  style: tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
                ),
              ],
            ),
          ),
          // Renaming carries no self-lockout risk (see the class doc), so
          // every row gets this control, including THIS device.
          const SizedBox(width: 8),
          renaming
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  key: Key('rename-action-${device.deviceFp}'),
                  onPressed: onRename,
                  tooltip: 'Rename',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  color: SovereignColors.textTertiary,
                ),
          // Safety property: THIS device never gets an Unlink control, the
          // server would reject it with a 400 anyway (see the class doc).
          if (!device.isCurrent) ...[
            const SizedBox(width: 8),
            busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    key: Key('unlink-action-${device.deviceFp}'),
                    onPressed: onUnlink,
                    style: TextButton.styleFrom(
                      foregroundColor: SovereignColors.accentDanger,
                    ),
                    child: const Text('Unlink'),
                  ),
          ],
        ],
      ),
    );
  }
}

/// The "Rename device" dialog content, pre-filled with [initialLabel] and
/// capped at 64 characters to match the server's own cap
/// (`device_routes.py:rename`). A StatefulWidget so its
/// [TextEditingController] is disposed by the framework itself once the
/// element genuinely unmounts, see [_LinkedDevicesScreenState._confirmRename]
/// for why that matters.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialLabel});

  final String initialLabel;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialLabel);
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _errorText = 'Name cannot be empty');
      return;
    }
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: SovereignColors.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Rename device'),
      content: TextField(
        key: const Key('rename-input-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(
          hintText: 'Device name',
          errorText: _errorText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: SovereignColors.textTertiary),
          ),
        ),
        FilledButton(
          key: const Key('rename-confirm-action'),
          onPressed: _submit,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// The pending-approval banner: every device that enrolled with the shared
/// operator token but has not been vouched for yet
/// (`GET /api/v1/operator/devices/pending`, [DeviceListService.listPending]).
///
/// This is a security surface, not a chore list. A row here is a device
/// nobody has confirmed belongs to the operator; if it is not recognized, it
/// is an intrusion attempt. So this uses the screen's existing danger
/// styling (the same [SovereignColors.accentDanger] the Unlink controls use)
/// rather than the milder amber [_NoOperatorSessionBanner] uses, Deny sits
/// at least as reachable as Approve on every row, and Approve is gated
/// behind [_LinkedDevicesScreenState._confirmApprove]'s named confirmation,
/// never a bare tap.
class _PendingDevicesBanner extends StatelessWidget {
  const _PendingDevicesBanner({
    required this.pending,
    required this.approvingFps,
    required this.denyingFps,
    required this.onApprove,
    required this.onDeny,
  });

  final List<LinkedDevice> pending;
  final Set<String> approvingFps;
  final Set<String> denyingFps;
  final void Function(LinkedDevice) onApprove;
  final void Function(LinkedDevice) onDeny;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final n = pending.length;
    return Container(
      key: const Key('pending-devices-banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SovereignColors.accentDanger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: SovereignColors.accentDanger.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.gpp_maybe_rounded,
                color: SovereignColors.accentDanger,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  n == 1
                      ? '1 device is waiting for approval'
                      : '$n devices are waiting for approval',
                  style: tt.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: SovereignColors.accentDanger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Text(
              'Each one linked using the operator token, but nobody has '
              'confirmed it belongs to you yet. If you do not recognize a '
              'device below, deny it.',
              style: tt.bodySmall
                  ?.copyWith(color: SovereignColors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          for (final device in pending) ...[
            _PendingDeviceRow(
              key: ValueKey('pending-${device.deviceFp}'),
              device: device,
              approving: approvingFps.contains(device.deviceFp),
              denying: denyingFps.contains(device.deviceFp),
              onApprove: () => onApprove(device),
              onDeny: () => onDeny(device),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _PendingDeviceRow extends StatelessWidget {
  const _PendingDeviceRow({
    super.key,
    required this.device,
    required this.approving,
    required this.denying,
    required this.onApprove,
    required this.onDeny,
  });

  final LinkedDevice device;
  final bool approving;
  final bool denying;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final label = deviceRowTitle(device);
    final platformLabel =
        device.platform.isNotEmpty ? device.platform : 'unknown';
    final busy = approving || denying;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: SovereignColors.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            _platformIcon(device.platform),
            color: SovereignColors.textTertiary,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '$platformLabel · waiting ${relativeLastSeen(device.enrolledAt)}',
                  style: tt.labelSmall
                      ?.copyWith(color: SovereignColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          denying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  key: Key('deny-action-${device.deviceFp}'),
                  onPressed: busy ? null : onDeny,
                  style: TextButton.styleFrom(
                    foregroundColor: SovereignColors.accentDanger,
                  ),
                  child: const Text('Deny'),
                ),
          const SizedBox(width: 4),
          approving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : OutlinedButton(
                  key: Key('approve-action-${device.deviceFp}'),
                  onPressed: busy ? null : onApprove,
                  child: const Text('Approve'),
                ),
        ],
      ),
    );
  }
}

class _NoOperatorSessionBanner extends StatelessWidget {
  const _NoOperatorSessionBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key("no-operator-session-banner"),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SovereignColors.accentWarning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: SovereignColors.accentWarning.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: SovereignColors.accentWarning,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No row here is marked "This device": you are connected with a '
              'shared operator token, not a signed-in operator session, so '
              'the actions below cannot succeed yet. Sign in with an '
              'operator session on this device to manage linked devices.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: SovereignColors.textSecondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThisDeviceChip extends StatelessWidget {
  const _ThisDeviceChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: SovereignColors.accentEncrypt.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'This device',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: SovereignColors.accentEncrypt,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

IconData _platformIcon(String platform) {
  switch (platform.toLowerCase()) {
    case 'android':
      return Icons.phone_android_rounded;
    case 'ios':
      return Icons.phone_iphone_rounded;
    case 'web':
      return Icons.public_rounded;
    case 'linux':
    case 'macos':
    case 'windows':
    case 'app':
      return Icons.laptop_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

/// This row's display title, with the same anti-spoof text-level marker
/// `guestDisplayTitle` (`packages/skchat_ui`) applies to a self-asserted
/// guest name: a `labelSource == 'client'` label is self-asserted by the
/// device itself, so it is prefixed `self-named:` in addition to the amber
/// italic styling ([_DeviceRow] applies that separately), never styling
/// alone, so the row cannot visually pass as one the server named even in a
/// place (a screen reader, a copy-pasted screenshot) that drops color.
/// `"derived"` gets the amber italic styling too (see [_DeviceRow]) but no
/// text marker here, the device never claimed that name, the server only
/// guessed it, so there is nothing to call out as self-asserted. Exposed
/// (not private) so this can be unit-tested directly, same reasoning as
/// [relativeLastSeen].
String deviceRowTitle(LinkedDevice device) {
  final label = device.label.isNotEmpty ? device.label : device.deviceFp;
  return device.labelSource == 'client' ? 'self-named: $label' : label;
}

/// Short "Xs/m/h/d ago" rendering of a `last_seen` epoch-seconds value
/// (matching the granularity `ProfileScreen`'s `_DaemonStatusCard` already
/// uses for its own "last poll" timestamp). Exposed (not private) so a test
/// can pin its boundaries directly instead of only observing them through a
/// pumped widget's clock-dependent text.
String relativeLastSeen(double epochSeconds) {
  if (epochSeconds <= 0) return 'never';
  final dt =
      DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).round());
  final diff = DateTime.now().difference(dt);
  if (diff.isNegative || diff.inSeconds < 10) return 'just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

// ── Empty / error states ────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.devices_other_rounded,
              size: 48,
              color: SovereignColors.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'No linked devices',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Link a device from its own Profile screen to see it here.',
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(color: SovereignColors.textSecondary),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onRefresh,
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
              ),
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 48,
              color: SovereignColors.accentDanger,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not load devices',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(color: SovereignColors.textSecondary),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: SovereignColors.soulLumina,
                foregroundColor: Colors.black,
              ),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
