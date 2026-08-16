import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../services/diag/diag_event.dart';
import '../../services/diag/diag_friendly.dart';
import '../../services/diag/diag_log_provider.dart';
import '../../services/health_service.dart';

/// Me > Logs: the screen this whole client-observability effort exists to
/// deliver. On 2026-08-13 the `.100` node died and the only client-visible
/// symptom was Lumina silently not answering; diagnosing it needed shell
/// access to a server. This screen answers "is the backend down" and "what
/// recently went wrong" from inside the app, no journalctl required.
///
/// Two independent halves (see the file's individual widgets):
///  - [_ProblemsSection]: the local ring buffer ([diagLogProvider]), works
///    fully offline, reverse-chronological, plain-language per event.
///  - [_HealthSection]: `GET /api/v1/health` on the server. Honesty rules
///    (never show green the client did not verify; `unknown` is a THIRD
///    state, not a stand-in for red or green; always show the data's own
///    timestamp) live in `health_service.dart` and are rendered, not
///    re-decided, here.
///
/// Rule 4 (do not gate the whole screen on the network call) is why these
/// are two independently-loading sections rather than one combined future:
/// the health fetch can hang or fail for as long as it likes without ever
/// blocking the problems list, which is exactly the moment an operator
/// needs it most.
class MeLogsScreen extends ConsumerStatefulWidget {
  const MeLogsScreen({super.key});

  @override
  ConsumerState<MeLogsScreen> createState() => _MeLogsScreenState();
}

class _MeLogsScreenState extends ConsumerState<MeLogsScreen> {
  /// `null` while the first fetch is still in flight. Never reset to `null`
  /// again after that: a manual refresh replaces it with a fresh result
  /// (possibly itself [HealthUnavailable]), never blanks the card back to
  /// a loading state a user has to wait through twice.
  HealthResult? _health;
  bool _refreshingHealth = false;

  List<DiagEvent> _events = const [];
  StreamSubscription<DiagEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _loadEventsSnapshot();
    _subscribeToNewEvents();
    unawaited(_loadHealth());
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  /// Reads whatever the ring buffer already holds, newest first. This is
  /// synchronous and never touches the network -- the reason half 1 renders
  /// immediately regardless of connectivity (honesty rule 4).
  void _loadEventsSnapshot() {
    final diagLog = ref.read(diagLogProvider);
    setState(() => _events = diagLog.events.reversed.toList());
  }

  /// Keeps the list live while the screen is open: a fresh `net.request_failed`
  /// firing WHILE the operator is looking at this screen (e.g. right after
  /// opening it because something just broke) shows up without a manual
  /// refresh.
  void _subscribeToNewEvents() {
    final diagLog = ref.read(diagLogProvider);
    _eventSub = diagLog.eventStream.listen((event) {
      if (!mounted) return;
      setState(() => _events = [event, ..._events]);
    });
  }

  Future<void> _loadHealth() async {
    if (mounted) setState(() => _refreshingHealth = true);
    // HealthService.fetch() already never throws (every failure branch --
    // unreachable, 404, unparseable -- returns a HealthUnavailable), but
    // wrapping it again here costs nothing and means a bug in that
    // contract can never take this whole screen down with it.
    HealthResult result;
    try {
      result = await ref.read(healthServiceProvider).fetch();
    } catch (_) {
      result = HealthUnavailable(
        reason: HealthUnavailableReason.unreachable,
        checkedAt: DateTime.now(),
      );
    }
    if (!mounted) return;
    setState(() {
      _health = result;
      _refreshingHealth = false;
    });
  }

  /// Only `error`/`warn` events read as "problems" -- `info`/`debug` (app
  /// lifecycle beats, etc) are not what an operator means by "what went
  /// wrong", and showing them would bury the signal this screen exists to
  /// surface. Newest first (the ring buffer's own order, reversed once in
  /// [_loadEventsSnapshot]/[_subscribeToNewEvents], not re-sorted here).
  List<DiagEvent> get _problemEvents => _events
      .where((e) => e.level == DiagLevel.error || e.level == DiagLevel.warn)
      .toList();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: SovereignColors.surfaceBase,
      appBar: AppBar(
        backgroundColor: SovereignColors.surfaceBase,
        title: const Text('Logs'),
        actions: [
          IconButton(
            key: const Key('me-logs-refresh-health'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Recheck service health',
            onPressed: _refreshingHealth ? null : () => unawaited(_loadHealth()),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _SectionHeading(label: 'Service health', textTheme: tt),
          _HealthSection(health: _health, refreshing: _refreshingHealth),
          const SizedBox(height: 24),
          _SectionHeading(label: 'Recent problems', textTheme: tt),
          _ProblemsSection(events: _problemEvents),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label, required this.textTheme});

  final String label;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: textTheme.labelSmall?.copyWith(
          color: SovereignColors.textTertiary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Half 2: service health ─────────────────────────────────────────────────

class _HealthSection extends StatelessWidget {
  const _HealthSection({required this.health, required this.refreshing});

  final HealthResult? health;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final result = health;
    if (result == null) {
      return const _HealthLoadingCard();
    }
    return switch (result) {
      HealthAvailable(:final report) => _HealthCard(
          key: const Key('health-card-available'),
          bannerText: refreshing ? 'Rechecking...' : null,
          bannerIsWarning: false,
          generatedAt: report.generatedAt,
          services: report.services,
        ),
      HealthUnavailable(:final reason, :final checkedAt) => _HealthCard(
          key: const Key('health-card-unavailable'),
          bannerText: _unavailableBannerText(reason),
          bannerIsWarning: true,
          generatedAt: checkedAt,
          services: result.placeholderServices,
        ),
    };
  }

  static String _unavailableBannerText(HealthUnavailableReason reason) {
    switch (reason) {
      case HealthUnavailableReason.unreachable:
        return "This app can't reach the server right now. Nothing below "
            'has been verified.';
      case HealthUnavailableReason.notDeployed:
        return "This server doesn't support service health checks yet. "
            'Nothing below has been verified.';
      case HealthUnavailableReason.unparseable:
        return "The server's health response couldn't be understood. "
            'Nothing below has been verified.';
    }
  }
}

class _HealthLoadingCard extends StatelessWidget {
  const _HealthLoadingCard();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      key: const Key('health-card-loading'),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(
            'Checking service health...',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: SovereignColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({
    super.key,
    required this.bannerText,
    required this.bannerIsWarning,
    required this.generatedAt,
    required this.services,
  });

  final String? bannerText;
  final bool bannerIsWarning;
  final DateTime generatedAt;
  final List<ServiceHealth> services;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bannerText != null)
            Container(
              key: const Key('health-unavailable-banner'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (bannerIsWarning
                        ? SovereignColors.accentWarning
                        : SovereignColors.textTertiary)
                    .withValues(alpha: 0.12),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    bannerIsWarning
                        ? Icons.wifi_off_rounded
                        : Icons.sync_rounded,
                    size: 18,
                    color: bannerIsWarning
                        ? SovereignColors.accentWarning
                        : SovereignColors.textTertiary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      bannerText!,
                      style: tt.bodySmall?.copyWith(
                        color: bannerIsWarning
                            ? SovereignColors.accentWarning
                            : SovereignColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Data as of ${relativeTimeAgo(generatedAt)}',
              style: tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
            ),
          ),
          for (final service in services) ...[
            _ServiceRow(key: ValueKey('service-row-${service.id}'), service: service),
            const Divider(height: 1, indent: 16),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({super.key, required this.service});

  final ServiceHealth service;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final (icon, color, stateWord) = switch (service.state) {
      // Three states, three fully distinct treatments (icon shape AND
      // color, never color alone): a colorblind operator, or a screenshot
      // that loses color, still tells `up` from `down` from `unknown` by
      // icon shape alone.
      ServiceHealthState.up => (
          Icons.check_circle_rounded,
          SovereignColors.accentEncrypt,
          'reachable',
        ),
      ServiceHealthState.down => (
          Icons.cancel_rounded,
          SovereignColors.accentDanger,
          'not reachable',
        ),
      ServiceHealthState.unknown => (
          Icons.help_outline_rounded,
          SovereignColors.textTertiary,
          'not verified',
        ),
    };
    final checkedText = 'Checked ${relativeTimeAgo(service.checkedAt)}';
    final detailText = service.detail;
    final semanticLabel = detailText != null && detailText.isNotEmpty
        ? '${service.label}: $stateWord, $checkedText, $detailText'
        : '${service.label}: $stateWord, $checkedText';

    // excludeSemantics: true so the row announces exactly this one
    // sentence -- never a fragmented icon-then-text-then-text read, and
    // never relying on the icon's color to carry meaning a screen reader
    // cannot see at all.
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color, key: Key('service-icon-${service.id}')),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    service.label,
                    style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detailText != null && detailText.isNotEmpty
                        ? '$checkedText - $detailText'
                        : checkedText,
                    style: tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
                  ),
                ],
              ),
            ),
            Text(
              stateWord,
              style: tt.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Half 1: recent problems ─────────────────────────────────────────────────

class _ProblemsSection extends StatelessWidget {
  const _ProblemsSection({required this.events});

  final List<DiagEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const _EmptyProblemsCard();
    }
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < events.length; i++) ...[
            _DiagEventTile(event: events[i]),
            if (i != events.length - 1) const Divider(height: 1, indent: 16),
          ],
        ],
      ),
    );
  }
}

class _EmptyProblemsCard extends StatelessWidget {
  const _EmptyProblemsCard();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return GlassCard(
      key: const Key('problems-empty-state'),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 40,
            color: SovereignColors.accentEncrypt,
          ),
          const SizedBox(height: 12),
          Text(
            'Nothing has gone wrong recently',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: SovereignColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagEventTile extends StatelessWidget {
  const _DiagEventTile({required this.event});

  final DiagEvent event;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final friendly = friendlyDiagEvent(event);
    final isError = event.level == DiagLevel.error;
    return ExpansionTile(
      key: Key('diag-event-${event.seq}'),
      leading: Icon(
        isError ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
        color: isError ? SovereignColors.accentDanger : SovereignColors.accentWarning,
        size: 20,
      ),
      title: Text(
        friendly.headline,
        style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        relativeTimeAgo(event.ts),
        style: tt.labelSmall?.copyWith(color: SovereignColors.textTertiary),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              friendly.detail,
              style: tt.labelSmall?.copyWith(
                color: SovereignColors.textTertiary,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Shared: relative time ────────────────────────────────────────────────

/// "Xs/m/h/d ago" rendering, DateTime-based (mirrors
/// `linked_devices_screen.dart`'s epoch-seconds `relativeLastSeen`, same
/// granularity). [now] defaults to the live clock but is overridable so a
/// test can pin the boundary being exercised instead of racing the real
/// clock. Exposed (not private) for the same reason `relativeLastSeen` is.
String relativeTimeAgo(DateTime at, {DateTime? now}) {
  final reference = (now ?? DateTime.now()).toUtc();
  final diff = reference.difference(at.toUtc());
  if (diff.isNegative || diff.inSeconds < 10) return 'just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
