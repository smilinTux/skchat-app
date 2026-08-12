import "dart:async";

import "package:flutter/material.dart";
import "package:skworld_module_api/skworld_module_api.dart";

import "skcode_api_client.dart";
import "skcode_job_run.dart";
import "skcode_jobs_list_store.dart";
import "skcode_session_screen.dart";
import "skcode_sessions_list_store.dart";
import "skcode_ws_transport.dart";

/// The sessions rail (card C-4 part 4, spec section 7): on phone this IS the
/// `/code` landing screen. Polls `GET /sessions` via [SkcodeSessionsListStore]
/// while mounted and pushes [SkcodeSessionScreen] full screen
/// (`/code/s/:sid`) when a row is tapped.
///
/// Beneath the sessions list sits the Jobs section (spec section 8, card
/// C-8): a read-only, separately-polled view of `GET /jobs` (the cron
/// ledger), rendered by [_JobsSection] below. Jobs are NOT sessions -- a
/// [SkcodeJobRun] never routes through [SkcodeSessionsListStore] or
/// `SkcodeSessionStore`'s event merge, and a job row never opens
/// [SkcodeSessionScreen] (no `sid`, nothing to stream). There is no
/// run-now/retry/cancel control anywhere in this section: v1 is view plus
/// the ledger's own `tail` summary, deliberately.
class SkcodeSessionsRail extends StatefulWidget {
  const SkcodeSessionsRail({
    super.key,
    required this.apiClient,
    required this.origin,
    required this.mintToken,
    required this.onAuthRejected,
    this.connectTransport = SkcodeWsTransport.connect,
    this.auth,
  });

  final SkcodeApiClient apiClient;
  final String origin;
  final Future<String?> Function() mintToken;
  final VoidCallback onAuthRejected;

  /// Forwarded to the pushed [SkcodeSessionScreen] (test seam: a widget test
  /// injects a fake transport so tapping a row never opens a real socket).
  final SkcodeWsTransport Function(Uri uri) connectTransport;

  /// Forwarded straight through to the pushed [SkcodeSessionScreen] (card
  /// C-5): the audience-scoped [AuthContext] its inject-composer scope gate
  /// reads via `hasScope(kSkcodeInjectScope)`.
  final AuthContext? auth;

  @override
  State<SkcodeSessionsRail> createState() => _SkcodeSessionsRailState();
}

class _SkcodeSessionsRailState extends State<SkcodeSessionsRail> {
  late final SkcodeSessionsListStore _store;
  List<SkcodeSessionSummary> _sessions = const [];
  StreamSubscription<List<SkcodeSessionSummary>>? _sub;

  @override
  void initState() {
    super.initState();
    _store = SkcodeSessionsListStore(
      apiClient: widget.apiClient,
      mintToken: widget.mintToken,
    );
    _sub = _store.sessions.listen((list) {
      if (mounted) setState(() => _sessions = list);
    });
    _store.startPolling();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _store.stopPolling();
    unawaited(_store.dispose());
    super.dispose();
  }

  void _openSession(BuildContext context, SkcodeSessionSummary session) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SkcodeSessionScreen(
          sid: session.sid,
          apiClient: widget.apiClient,
          origin: widget.origin,
          mintToken: widget.mintToken,
          onAuthRejected: widget.onAuthRejected,
          connectTransport: widget.connectTransport,
          auth: widget.auth,
          // AC4's other half: the focused session must itself be
          // interactive (`SkcodeSessionSummary.mode == "interactive"`) for
          // the inject composer to render at all.
          interactive: session.mode == "interactive",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: _sessions.isEmpty
              ? const Center(child: Text("No sessions yet"))
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return _SessionTile(
                      session: session,
                      onTap: () => _openSession(context, session),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "Jobs",
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: _JobsSection(
            apiClient: widget.apiClient,
            mintToken: widget.mintToken,
          ),
        ),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onTap});

  final SkcodeSessionSummary session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRunning = session.state == "running";
    final subtitleParts = [
      if (session.lastMessage.isNotEmpty) session.lastMessage,
      if (session.repo.isNotEmpty) session.repo,
      session.harness,
    ].where((s) => s.isNotEmpty).toList();

    return ListTile(
      key: ValueKey(session.sid),
      leading: Icon(
        Icons.circle,
        size: 10,
        color: isRunning ? Colors.green : Theme.of(context).disabledColor,
      ),
      title: Text(session.sid),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(" · ")),
      onTap: onTap,
    );
  }
}

/// The Jobs section (spec section 8, card C-8): owns its own
/// [SkcodeJobsListStore] (a separate poll from the sessions list above --
/// see the store's own doc comment for why) and renders one of four states,
/// each an explicit, honest render rather than a blank area:
///
///  * not yet polled: nothing (a beat before the first poll resolves).
///  * never succeeded and the last attempt failed: "Jobs unavailable".
///  * succeeded, zero rows: "No scheduled jobs".
///  * succeeded, N rows: one [_JobTile] per row, newest data always shown
///    (a later failed poll keeps the last-known-good list rather than
///    blanking it, matching the sessions list's own "one missed tick is not
///    an error" rule).
///
/// No row here is tappable and nothing here ever calls into hostd: v1 is
/// view-only, deliberately (card C-8: "no run-now, cancel; deliberately
/// deferred").
class _JobsSection extends StatefulWidget {
  const _JobsSection({required this.apiClient, required this.mintToken});

  final SkcodeApiClient apiClient;
  final Future<String?> Function() mintToken;

  @override
  State<_JobsSection> createState() => _JobsSectionState();
}

class _JobsSectionState extends State<_JobsSection> {
  late final SkcodeJobsListStore _store;
  SkcodeJobsPoll? _snapshot;
  StreamSubscription<SkcodeJobsPoll>? _sub;

  @override
  void initState() {
    super.initState();
    _store = SkcodeJobsListStore(
      apiClient: widget.apiClient,
      mintToken: widget.mintToken,
    );
    _sub = _store.jobs.listen((poll) {
      if (mounted) setState(() => _snapshot = poll);
    });
    _store.startPolling();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _store.stopPolling();
    unawaited(_store.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      // No poll has resolved yet: not "unavailable" (that is a judgment
      // about a completed attempt) and not "empty" (that is a judgment
      // about a completed successful attempt). Render nothing for this one
      // beat rather than guess.
      return const SizedBox.shrink();
    }
    if (!snapshot.everSucceeded && snapshot.failed) {
      return const Center(
        key: Key("skcodeJobsUnavailable"),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text("Jobs unavailable"),
        ),
      );
    }
    if (snapshot.jobs.isEmpty) {
      return const Center(
        key: Key("skcodeJobsEmpty"),
        child: Text("No scheduled jobs"),
      );
    }
    return ListView.builder(
      key: const Key("skcodeJobsList"),
      itemCount: snapshot.jobs.length,
      itemBuilder: (context, index) => _JobTile(job: snapshot.jobs[index]),
    );
  }
}

/// Maps a [SkcodeJobRun.status] string straight from the server to a color.
/// No thresholding, no interpretation beyond the literal three values the
/// server ever sends ("ok" | "failed" | "unknown"); anything unrecognized
/// (there should never be a fourth value, but this must never crash on one)
/// falls into the same neutral color as "unknown".
Color _jobStatusColor(BuildContext context, String status) {
  switch (status) {
    case "ok":
      return Colors.green;
    case "failed":
      return Theme.of(context).colorScheme.error;
    default:
      return Theme.of(context).colorScheme.onSurfaceVariant;
  }
}

String _jobStatusLabel(String status) {
  switch (status) {
    case "ok":
      return "OK";
    case "failed":
      return "Failed";
    default:
      return "Unknown";
  }
}

/// Formats [stalenessS] (seconds elapsed since the job's last run, as
/// computed by the server) into a short "Xm ago" style string for the row
/// subtitle. Pure unit formatting only -- this performs no threshold
/// comparison and never decides whether the job IS stale; that verdict
/// comes from [SkcodeJobRun.stale] alone (see [_StalenessBadge]).
String _formatJobAge(double? stalenessS) {
  if (stalenessS == null) return "no runs yet";
  final totalSeconds = stalenessS < 0 ? 0 : stalenessS.round();
  if (totalSeconds < 60) return "${totalSeconds}s ago";
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return "${minutes}m ago";
  final hours = minutes ~/ 60;
  if (hours < 24) return "${hours}h ago";
  final days = hours ~/ 24;
  return "${days}d ago";
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});

  final SkcodeJobRun job;

  @override
  Widget build(BuildContext context) {
    final statusColor = _jobStatusColor(context, job.status);
    final subtitleParts = [
      _formatJobAge(job.stalenessS),
      _jobStatusLabel(job.status),
      if (job.host.isNotEmpty) job.host,
      if (job.tail.isNotEmpty) job.tail,
    ].where((s) => s.isNotEmpty).toList();

    return ListTile(
      key: ValueKey("skcodeJob-${job.job}"),
      // No onTap: a job row never navigates anywhere (there is no session
      // screen for a JobRun to open -- it has no sid) and there is no
      // mutating action to trigger.
      leading: Icon(Icons.circle, size: 10, color: statusColor),
      title: Text(job.job),
      subtitle: Text(subtitleParts.join(" · ")),
      trailing: _StalenessBadge(stale: job.stale),
    );
  }
}

/// The staleness badge (card C-8: "staleness must be visually obvious at a
/// glance"). Driven ENTIRELY by [SkcodeJobRun.stale], the server's own
/// verdict -- this widget performs no staleness computation itself, only
/// renders the one bit it was given as two visually distinct states (color,
/// border, and label all differ, so the signal survives color-blindness and
/// grayscale screenshots alike).
class _StalenessBadge extends StatelessWidget {
  const _StalenessBadge({required this.stale});

  final bool stale;

  @override
  Widget build(BuildContext context) {
    final color = stale ? Theme.of(context).colorScheme.error : Colors.green;
    return Container(
      key: Key(stale ? "skcodeJobBadgeStale" : "skcodeJobBadgeFresh"),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        stale ? "STALE" : "FRESH",
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}
