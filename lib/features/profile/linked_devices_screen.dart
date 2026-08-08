import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../services/device_list_service.dart';

/// "Linked Devices" screen: every device enrolled to this operator identity
/// (`GET /api/v1/operator/devices`, via [DeviceListService.list]), with a
/// per-device Unlink action and a bulk "Unlink all other devices" action.
///
/// THIS device (server-computed [LinkedDevice.isCurrent]) never renders an
/// Unlink control, that is a safety property, not decoration: the server
/// rejects a self-unlink with a 400
/// ([DeviceUnlinkFailureReason.selfUnlink]), so offering the action here
/// would put an affordance on screen for something that cannot succeed.
///
/// A device's [LinkedDevice.label] is self-asserted by that device unless
/// [LinkedDevice.labelSource] is `"operator"` (today the server only ever
/// records `"client"` or `"derived"`, see `operator_auth_routes.py`'s
/// `_record_enrollment`, both self-asserted; `"operator"` is left open for a
/// future operator-set rename). Anything not `"operator"` renders with the
/// SAME untrusted styling the rest of the app already uses for a
/// self-asserted guest name (see `guestDisplayTitle` /
/// `ConversationMember.isUntrustedName` in `packages/skchat_ui`, and the
/// mirrored per-row style in `group_info_screen.dart`): amber, italic. No new
/// styling is invented here.
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
  String _errorMessage = '';

  /// Fingerprints currently mid-unlink: their row shows a spinner instead of
  /// the Unlink button, so a slow request cannot be double-tapped.
  final Set<String> _busyFps = {};
  bool _busyAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = _LoadState.loading);
    try {
      final devices = await ref.read(deviceListServiceProvider).list();
      if (!mounted) return;
      setState(() {
        _devices = devices;
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
    if (_devices.isEmpty) {
      return _EmptyView(onRefresh: _load);
    }
    final hasOthers = _devices.any((d) => !d.isCurrent);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          for (final device in _devices) ...[
            _DeviceRow(
              key: ValueKey(device.deviceFp),
              device: device,
              busy: _busyFps.contains(device.deviceFp),
              onUnlink: () => _confirmUnlink(device),
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
    required this.onUnlink,
  });

  final LinkedDevice device;
  final bool busy;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final untrusted = device.labelSource != 'operator';
    final label = device.label.isNotEmpty ? device.label : device.deviceFp;
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
