import "package:flutter/material.dart";

import "skcode_digest.dart";

/// The Digest tab's load state (card C-9). Distinct honest states, never a
/// crash and never a blank pane (card constraint: "degrade honestly: no
/// digest published yet, fetch fails, or malformed content must render a
/// clear empty or error state").
enum _DigestPhase { loading, notConfigured, notFound, error, loaded }

/// The Digest tab (card C-9, spec section 9): fetches the skwatchdog
/// published `latest/` artifact over https and renders it natively, with
/// every `skworld://`/`https://` link tappable through [onOpenLink].
///
/// This widget owns NO state beyond what one fetch returns: no disk cache, no
/// re-derived counts, nothing recomputed from the events it renders (the
/// division-of-labor rule: "the watchdog collects, narrates, and files ...
/// neither owns the other's data"). A pull-to-refresh / retry re-fetches the
/// same URL; it never remembers the previous result once a new fetch starts.
class SkcodeDigestTab extends StatefulWidget {
  const SkcodeDigestTab({
    super.key,
    this.digestUrl,
    this.onOpenLink,
    this.client,
  });

  /// The full `latest/` digest artifact URL (watchdog spec section 5: "the
  /// digest publishes next to the Atlas brief"). Null means no digest host is
  /// configured yet, which renders the same honest empty state as a 404 would
  /// (see [_DigestPhase.notConfigured]), never a crash.
  final String? digestUrl;

  /// Invoked with a link's resolved target (`link.uri` when the event
  /// carries a shell-resolvable `skworld://` uri, else its `https://`
  /// fallback) when a digest line is tapped. The module boundary seam (card
  /// C-9, mirroring card C-3b's `origin`/`onAuthRejected`): this package
  /// cannot import host routing (the import gate forbids it), so resolving
  /// the link is entirely the caller's job. The mounted host wires this to
  /// `shell.bus.navigate` (`SkcodeSurface`), which is "the shell router"
  /// `skworld://` links were always meant to land on (watchdog spec section
  /// 8). Null renders every link inert rather than crashing.
  final void Function(String uri)? onOpenLink;

  /// Test seam: inject a fake [SkcodeDigestClient] so a widget test never
  /// opens a real socket. Production always omits this.
  final SkcodeDigestClient? client;

  @override
  State<SkcodeDigestTab> createState() => _SkcodeDigestTabState();
}

class _SkcodeDigestTabState extends State<SkcodeDigestTab> {
  late final SkcodeDigestClient _client;
  _DigestPhase _phase = _DigestPhase.loading;
  SkcodeDigest? _digest;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? SkcodeDigestClient();
    _load();
  }

  @override
  void didUpdateWidget(covariant SkcodeDigestTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.digestUrl != widget.digestUrl) _load();
  }

  Future<void> _load() async {
    final url = widget.digestUrl;
    if (url == null || url.isEmpty) {
      if (!mounted) return;
      setState(() {
        _phase = _DigestPhase.notConfigured;
        _digest = null;
        _errorMessage = null;
      });
      return;
    }
    setState(() => _phase = _DigestPhase.loading);
    try {
      final digest = await _client.fetchLatest(url);
      if (!mounted) return;
      setState(() {
        _digest = digest;
        _phase = _DigestPhase.loaded;
      });
    } on SkcodeDigestNotFoundException {
      if (!mounted) return;
      setState(() => _phase = _DigestPhase.notFound);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _DigestPhase.error;
        _errorMessage = e.toString();
      });
    }
  }

  void _openLink(SkcodeDigestLink link) {
    if (link.isEmpty) return;
    widget.onOpenLink?.call(link.preferred);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _DigestPhase.loading:
        return const Center(child: CircularProgressIndicator());
      case _DigestPhase.notConfigured:
        return const _DigestState(
          icon: Icons.summarize_outlined,
          message: "Digest not configured",
        );
      case _DigestPhase.notFound:
        return const _DigestState(
          icon: Icons.summarize_outlined,
          message: "No digest published yet",
        );
      case _DigestPhase.error:
        return _DigestState(
          icon: Icons.error_outline,
          message: "Could not load the digest",
          detail: _errorMessage,
          onRetry: _load,
        );
      case _DigestPhase.loaded:
        return _DigestContent(digest: _digest!, onOpenLink: _openLink);
    }
  }
}

/// The shared empty/error shape for every non-loaded phase: icon, message,
/// an optional detail line, an optional Retry action. Kept local to this
/// file (not shared with `_EmptyArtifactState` in `skcode_artifact_pane.dart`,
/// which is private to that file) rather than promoted to a shared widget,
/// since only this tab needs the Retry action.
class _DigestState extends StatelessWidget {
  const _DigestState({
    required this.icon,
    required this.message,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 8),
            Text(message, style: Theme.of(context).textTheme.bodySmall),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text("Retry")),
            ],
          ],
        ),
      ),
    );
  }
}

/// The loaded digest: headline, then Problems, then Notable, each line
/// tappable when it carries a link. `info_counts` renders as a single
/// trailing summary line rather than a breakdown (this tab is a renderer,
/// not a second collector; see `SkcodeDigest.infoCount`'s doc comment).
class _DigestContent extends StatelessWidget {
  const _DigestContent({required this.digest, required this.onOpenLink});

  final SkcodeDigest digest;
  final void Function(SkcodeDigestLink link) onOpenLink;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final rows = <Widget>[];

    if (digest.date.isNotEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Text(digest.date, style: textTheme.bodySmall),
        ),
      );
    }
    if (digest.headline.isNotEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(digest.headline, style: textTheme.titleSmall),
        ),
      );
    }
    if (digest.problems.isNotEmpty) {
      rows.add(_SectionLabel(label: "Problems", count: digest.problems.length));
      rows.addAll(
        digest.problems.map(
          (e) => _DigestEventRow(event: e, onOpenLink: onOpenLink),
        ),
      );
    }
    if (digest.notable.isNotEmpty) {
      rows.add(_SectionLabel(label: "Notable", count: digest.notable.length));
      rows.addAll(
        digest.notable.map(
          (e) => _DigestEventRow(event: e, onOpenLink: onOpenLink),
        ),
      );
    }
    if (digest.problems.isEmpty && digest.notable.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text("Nothing firing or notable.", style: textTheme.bodySmall),
        ),
      );
    }
    if (digest.infoCount > 0) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Text(
            "${digest.infoCount} quiet events",
            style: textTheme.bodySmall?.copyWith(
              color: Theme.of(context).disabledColor,
            ),
          ),
        ),
      );
    }

    return ListView(children: rows);
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        "$label ($count)",
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

class _DigestEventRow extends StatelessWidget {
  const _DigestEventRow({required this.event, required this.onOpenLink});

  final SkcodeDigestEvent event;
  final void Function(SkcodeDigestLink link) onOpenLink;

  IconData get _severityIcon => switch (event.severity) {
    "problem" => Icons.error_outline,
    "notable" => Icons.info_outline,
    _ => Icons.circle_outlined,
  };

  Color _severityColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (event.severity) {
      "problem" => scheme.error,
      "notable" => Colors.amber,
      _ => scheme.onSurfaceVariant,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hasLink = !event.link.isEmpty;
    final captionParts = [
      if (event.source.isNotEmpty) event.source,
      if (event.kind.isNotEmpty) event.kind,
      if (event.object.isNotEmpty) event.object,
    ];

    return ListTile(
      key: ValueKey(event.ref.isNotEmpty ? event.ref : event.summary),
      dense: true,
      leading: Icon(_severityIcon, color: _severityColor(context)),
      title: Text(
        event.summary.isEmpty ? "(no summary)" : event.summary,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      subtitle: captionParts.isEmpty
          ? null
          : Text(
              captionParts.join(" · "),
              style: Theme.of(context).textTheme.bodySmall,
            ),
      trailing: hasLink ? const Icon(Icons.chevron_right) : null,
      onTap: hasLink ? () => onOpenLink(event.link) : null,
    );
  }
}
