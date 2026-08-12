/// One row of `GET /skcode/api/v1/jobs` (skcode Code-section card C-8, spec
/// section 8), mirroring skharness's `JobRun.to_dict()`
/// (`skharness/src/skharness/jobs.py`) field-for-field.
///
/// Deliberately NOT a [SkcodeSessionSummary]: a cron/scheduler run is not a
/// session, has no `sid`, and is owned by the scheduler's cron ledger
/// (`~/.skcapstone/logs/cron-ledger.jsonl`), not hostd's session registry.
/// Nothing in this package folds a [SkcodeJobRun] into
/// `SkcodeSessionStore`/`SkcodeSessionsListStore` or the session event
/// merge, and nothing here recomputes [stale] / [stalenessS]: the server
/// already derives both from the job's own run cadence (card C-8's
/// "freshness IS liveness" rule) and this client only ever displays what it
/// was sent.
class SkcodeJobRun {
  const SkcodeJobRun({
    required this.job,
    this.host = "",
    this.lastStart,
    this.status = "unknown",
    this.durS,
    this.tail = "",
    this.stalenessS,
    this.stale = true,
    this.staleThresholdS = 0,
  });

  final String job;
  final String host;

  /// ISO-8601 timestamp of the job's most recent run, or null when the
  /// ledger has no parseable timestamp for it.
  final String? lastStart;

  /// "ok" | "failed" | "unknown", straight from the server
  /// (`skharness.jobs._status_of`). A record with a missing/non-boolean
  /// `ok` field already degrades to "unknown" server-side; this client
  /// never reinterprets the string, only maps it to a label/color.
  final String status;

  final double? durS;

  /// Short log excerpt for the run, straight from the ledger: the "view
  /// plus a link to logs only" the card allows in place of any new
  /// log-serving surface here.
  final String tail;

  /// Seconds since the job's last run, server-computed. Null when the
  /// ledger has no parseable timestamp for the job.
  final double? stalenessS;

  /// Server-computed: true once [stalenessS] exceeds the job's own inferred
  /// cadence threshold (or when the last run's timestamp could not be
  /// parsed at all, per `skharness.jobs.read_job_runs`). NEVER recomputed
  /// client-side; this field alone drives the staleness badge.
  final bool stale;

  /// The threshold (seconds) [stale] was judged against, for anyone who
  /// wants to show it (e.g. a tooltip); not required by v1's row.
  final double staleThresholdS;

  factory SkcodeJobRun.fromJson(Map<String, dynamic> json) {
    return SkcodeJobRun(
      job: json["job"] as String? ?? "",
      host: json["host"] as String? ?? "",
      lastStart: json["last_start"] as String?,
      status: json["status"] as String? ?? "unknown",
      durS: (json["dur_s"] as num?)?.toDouble(),
      tail: json["tail"] as String? ?? "",
      stalenessS: (json["staleness_s"] as num?)?.toDouble(),
      stale: json["stale"] as bool? ?? true,
      staleThresholdS: (json["stale_threshold_s"] as num?)?.toDouble() ?? 0,
    );
  }
}
