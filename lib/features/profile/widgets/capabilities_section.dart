import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/theme.dart';
import '../../../services/capabilities_service.dart';

/// "Services & Transports" section for the Me screen.
///
/// Fetches the node capability document from the SKComms daemon and renders two
/// labeled groups — Transports and Services — each as a status row with a
/// colored dot (green=up, amber=configured/degraded, grey=unconfigured/down)
/// and a protocol/rail label. Degrades gracefully: when the endpoint is missing
/// or unreachable the section quietly renders nothing (the rest of the Me
/// screen — daemon health + transport summary — is unaffected).
class CapabilitiesSection extends ConsumerWidget {
  const CapabilitiesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(nodeCapabilitiesProvider);
    return async.when(
      // Older daemon / offline → render nothing (graceful).
      error: (_, _) => const SizedBox.shrink(),
      loading: () => const SizedBox.shrink(),
      data: (caps) {
        if (caps == null || caps.isEmpty) return const SizedBox.shrink();
        return CapabilitiesView(caps: caps);
      },
    );
  }
}

/// Stateless renderer for a [NodeCapabilities] document — split out so it can be
/// widget-tested with a mock document, no daemon required.
class CapabilitiesView extends StatelessWidget {
  const CapabilitiesView({super.key, required this.caps});

  final NodeCapabilities caps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel(label: 'Services & Transports'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _GroupHeader(
                  icon: Icons.lan_outlined,
                  label: 'Transports',
                ),
                const SizedBox(height: 10),
                for (final t in caps.transports)
                  _CapRow(
                    key: Key('transport-${t.id}'),
                    title: _transportLabel(t.id),
                    subtitle: t.protocol,
                    trailing: t.media.isNotEmpty ? t.media.join(' · ') : null,
                    status: t.status,
                  ),
                if (caps.services.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Divider(
                    height: 1,
                    color: SovereignColors.surfaceGlassBorder,
                  ),
                  const SizedBox(height: 16),
                  _GroupHeader(
                    icon: Icons.apps_outlined,
                    label: 'Services',
                  ),
                  const SizedBox(height: 10),
                  for (final s in caps.services)
                    _CapRow(
                      key: Key('service-${s.id}'),
                      title: _serviceLabel(s.id),
                      subtitle: s.via.isNotEmpty ? 'via ${s.via.join(', ')}' : null,
                      status: s.status,
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

// ── Human-friendly labels ────────────────────────────────────────────────────

String _transportLabel(String id) {
  switch (id) {
    case 'file':
      return 'File';
    case 'syncthing':
      return 'Syncthing';
    case 'https-s2s':
      return 'HTTPS (S2S)';
    case 'websocket':
      return 'WebSocket';
    case 'tailscale':
      return 'Tailscale';
    case 'webrtc':
      return 'WebRTC';
    case 'p2p':
      return 'P2P';
    case 'ble-mesh':
      return 'BLE Mesh';
    case 'lora':
      return 'LoRa';
    case 'nostr':
      return 'Nostr';
    default:
      return id;
  }
}

String _serviceLabel(String id) {
  switch (id) {
    case 'text':
      return 'Chat';
    case 'voice':
      return 'Voice';
    case 'video':
      return 'Video';
    case 'file-transfer':
      return 'File transfer';
    case 'data-streaming':
      return 'Data streaming';
    case 'federation':
      return 'Federation';
    case 'access-plane':
      return 'Access plane';
    case 'geo-cot':
      return 'Geo / CoT';
    default:
      return id;
  }
}

// ── Status → color/label ─────────────────────────────────────────────────────

({Color color, String label}) _statusStyle(CapStatus status) {
  switch (status) {
    case CapStatus.up:
      return (color: SovereignColors.accentEncrypt, label: 'up'); // green
    case CapStatus.configured:
      return (color: SovereignColors.accentWarning, label: 'configured'); // amber
    case CapStatus.degraded:
      return (color: SovereignColors.accentWarning, label: 'degraded'); // amber
    case CapStatus.down:
      return (color: SovereignColors.textTertiary, label: 'down'); // grey
    case CapStatus.unconfigured:
      return (color: SovereignColors.textTertiary, label: 'unconfigured'); // grey
    case CapStatus.unknown:
      return (color: SovereignColors.textTertiary, label: 'unknown'); // grey
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: SovereignColors.textTertiary),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: SovereignColors.textTertiary,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}

class _CapRow extends StatelessWidget {
  const _CapRow({
    super.key,
    required this.title,
    required this.status,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? trailing;
  final CapStatus status;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final style = _statusStyle(status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          // Status dot.
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: style.color,
              shape: BoxShape.circle,
              boxShadow: status == CapStatus.up
                  ? [BoxShadow(color: style.color.withValues(alpha: 0.5), blurRadius: 6)]
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: tt.bodyMedium?.copyWith(
                    color: SovereignColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: tt.labelSmall?.copyWith(
                      color: SovereignColors.textTertiary,
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10.5,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: tt.labelSmall?.copyWith(
                color: SovereignColors.textSecondary,
                fontSize: 10.5,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Text(
            style.label,
            style: tt.labelSmall?.copyWith(
              color: style.color,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: SovereignColors.textTertiary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
