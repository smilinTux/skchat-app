import "package:flutter/material.dart";

import "skcode_api_client.dart";
import "skcode_digest.dart";

/// The Digest tab's load state (cards C-9, C-14a). Four distinct failure
/// states plus the loaded one, never a crash and never a blank pane.
///
/// The whole point of the split (card C-14a, mirroring what card C-19 did for
/// the sessions rail): "no digest exists", "you are not authorized", "the
/// published digest is corrupt", and "the host did not answer" are four
/// different problems with four different fixes, and a real digest with
/// nothing firing is a fifth thing again -- a genuinely quiet day, rendered by
/// [_DigestContent], not by any state here. Collapsing any of them into one
/// generic empty pane is the bug this enum exists to prevent.
enum _DigestPhase {
  loading,

  /// hostd answered 404: nothing has been published (the watchdog may simply
  /// not have run). NEVER the same render as a real digest with no events.
  notFound,

  /// No usable token reached hostd: never minted, or minted and rejected with
  /// a 401 even after one re-mint retry. Both point at the same next action
  /// (sign in again), so they share one state, exactly as the rail's own
  /// `SkcodeSessionsFailureKind.unauthorized` does.
  unauthorized,

  /// hostd answered 200 with bytes that will not parse: the published artifact
  /// is corrupt. hostd serves it unexamined by design, so this is a real,
  /// reachable state and not a defensive branch.
  corrupt,

  /// hostd did not answer at all: connection refused, DNS, timeout, funnel
  /// down, or any other non-401 transport/HTTP failure.
  unreachable,

  loaded,
}

/// The Digest tab (cards C-9, C-14a; spec section 9): fetches the skwatchdog
/// published digest from skcode-hostd and renders it natively, with every
/// `skworld://`/`https://` link tappable through [onOpenLink].
///
/// Card C-9 built the renderer against a bare, unauthenticated `digestUrl`
/// that nothing ever served, so this tab was inert from the day it shipped.
/// Card C-14a points it at hostd's `GET /api/v1/watchdog/digest` instead
/// ([SkcodeApiClient.fetchDigest]), carried by the same
/// `Authorization: Bearer` header and the same [onAuthRejected] re-mint seam that
/// sessions and jobs already use. There is no second HTTP path and no second
/// re-mint mechanism.
///
/// This widget owns NO state beyond what one fetch returns: no disk cache, no
/// re-derived counts, nothing recomputed from the events it renders (the
/// division-of-labor rule: "the watchdog collects, narrates, and files ...
/// neither owns the other's data"). Retry re-fetches; it never remembers the
/// previous result once a new fetch starts.
class SkcodeDigestTab extends StatefulWidget {
  const SkcodeDigestTab({
    super.key,
    required this.apiClient,
    required this.mintToken,
    this.onAuthRejected,
    this.onOpenLink,
  });

  /// The shared skcode-hostd client (card C-3b), the SAME instance the
  /// sessions rail and jobs list use. The digest is one more read on that
  /// plane, not a host of its own.
  final SkcodeApiClient apiClient;

  /// Mints the `skcode.stream`-scoped wire token, exactly as the sessions
  /// rail's own `mintToken` does. Resolving null means no token exists at all
  /// (standalone, or a host that never wired a minter), which renders
  /// [_DigestPhase.unauthorized]: the same operator-facing fact as a rejected
  /// token, and the same next action.
  final Future<String?> Function() mintToken;

  /// Invoked on a 401 so the host can drop its cached audience token and let
  /// the next [mintToken] genuinely re-mint (card C-3b). This tab re-mints at
  /// most ONCE per load and then stops: a fresh token that is rejected too is
  /// an honest [_DigestPhase.unauthorized], never a retry loop.
  final VoidCallback? onAuthRejected;

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

  @override
  State<SkcodeDigestTab> createState() => _SkcodeDigestTabState();
}

class _SkcodeDigestTabState extends State<SkcodeDigestTab> {
  _DigestPhase _phase = _DigestPhase.loading;
  SkcodeDigest? _digest;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SkcodeDigestTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.apiClient, widget.apiClient)) _load();
  }

  /// One load attempt, with at most one re-mint retry on a 401 (the same
  /// budget `SkcodeSessionStore` gives its own auth path: re-mint once, and if
  /// the fresh token is rejected too, surface it rather than loop).
  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _phase = _DigestPhase.loading;
        _errorMessage = null;
      });
    }
    var reminted = false;
    while (true) {
      final token = await widget.mintToken();
      if (token == null) {
        // Tokenless: nothing to send. Same operator message as a 401 below.
        _settle(_DigestPhase.unauthorized);
        return;
      }
      try {
        final digest = await widget.apiClient.fetchDigest(token: token);
        if (!mounted) return;
        setState(() {
          _digest = digest;
          _phase = _DigestPhase.loaded;
          _errorMessage = null;
        });
        return;
      } on SkcodeUnauthorizedException {
        if (reminted) {
          _settle(_DigestPhase.unauthorized);
          return;
        }
        reminted = true;
        widget.onAuthRejected?.call();
        continue;
      } on SkcodeDigestNotFoundException {
        _settle(_DigestPhase.notFound);
        return;
      } on SkcodeDigestParseException catch (e) {
        _settle(_DigestPhase.corrupt, detail: e.message);
        return;
      } catch (e) {
        _settle(_DigestPhase.unreachable, detail: e.toString());
        return;
      }
    }
  }

  void _settle(_DigestPhase phase, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _digest = null;
      _errorMessage = detail;
    });
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
      case _DigestPhase.notFound:
        return _DigestState(
          key: const Key("skcodeDigestNotFound"),
          icon: Icons.summarize_outlined,
          message: "No digest published yet",
          detail: "The watchdog has not published a digest for this fleet yet.",
          onRetry: _load,
        );
      case _DigestPhase.unauthorized:
        return _DigestState(
          key: const Key("skcodeDigestUnauthorized"),
          icon: Icons.lock_outline,
          message: "Not authorized to read the digest",
          detail:
              "Your session token was not issued or was rejected. Sign in again to continue.",
          onRetry: _load,
        );
      case _DigestPhase.corrupt:
        return _DigestState(
          key: const Key("skcodeDigestCorrupt"),
          icon: Icons.broken_image_outlined,
          message: "The published digest could not be read",
          detail: _errorMessage == null
              ? "A digest was published, but its content is not valid JSON."
              : "A digest was published, but its content is not valid JSON. ${_errorMessage!}",
          onRetry: _load,
        );
      case _DigestPhase.unreachable:
        return _DigestState(
          key: const Key("skcodeDigestUnreachable"),
          icon: Icons.cloud_off,
          message: "Could not reach the digest",
          detail: "skcode-hostd did not respond. Check the connection and try again.",
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
    super.key,
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
      // A REAL digest that happens to carry no problems and nothing notable:
      // a genuinely quiet day. Deliberately worded so it can never be read as
      // "no digest exists" (which is _DigestPhase.notFound, a different state
      // with a different icon, a different message, and a different fix).
      rows.add(
        Padding(
          key: const Key("skcodeDigestQuietDay"),
          padding: const EdgeInsets.all(16),
          child: Text(
            "Nothing firing or notable in this digest.",
            style: textTheme.bodySmall,
          ),
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
