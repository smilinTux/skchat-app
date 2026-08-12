import "dart:async";

import "skcode_api_client.dart";
import "skcode_job_run.dart";

/// One poll's outcome for [SkcodeJobsListStore]'s stream: either a fresh
/// list from a successful `GET /skcode/api/v1/jobs` call, or a failure
/// marker carrying forward the last successfully known list.
///
/// Kept as its own type (rather than the bare `List<SkcodeJobRun>`
/// `SkcodeSessionsListStore` streams) because the Jobs section's degrade
/// rule (card C-8: "endpoint unavailable, empty job list, or a job with
/// status unknown must each render a clear state") needs to tell "never
/// fetched successfully" apart from "fetched successfully, zero jobs" --
/// both look like an empty list otherwise.
class SkcodeJobsPoll {
  const SkcodeJobsPoll({
    required this.jobs,
    required this.everSucceeded,
    required this.failed,
  });

  final List<SkcodeJobRun> jobs;

  /// True once at least one poll has ever returned successfully.
  final bool everSucceeded;

  /// True when the MOST RECENT poll attempt failed (no token yet, or a
  /// transport/HTTP error talking to skcode-hostd). [jobs] still carries
  /// the last successful list when one exists, so a transient blip does not
  /// blank an otherwise-working section -- matching
  /// `SkcodeSessionsListStore`'s "one missed tick is not an error state"
  /// rule.
  final bool failed;
}

/// Polls `GET /skcode/api/v1/jobs` at [pollInterval] while [startPolling]
/// has been called and [stopPolling] has not. Shaped like
/// `SkcodeSessionsListStore` (same start/stop/dispose lifecycle, same
/// "skip the poll on a null token, swallow transport errors" behavior) but
/// deliberately a SEPARATE class: a `JobRun` is not a `SkcodeSessionSummary`
/// and this store is never merged into `SkcodeSessionsListStore` or
/// `SkcodeSessionStore`'s event merge (card C-8's "cron runs are JobRun
/// records and are never emitted as SessionEvents" acceptance criterion).
///
/// The cron ledger itself changes far less often than a live session's
/// event stream, so this polls on a longer cadence than the 15s sessions
/// poll; freshness here is about "did the scheduler run on schedule",
/// measured in minutes/hours, not seconds.
///
/// This store caches the last-fetched list only in memory, for exactly as
/// long as the section widget stays mounted; it is never written to disk
/// and never recomputes staleness (card C-8's "the Code section is a view,
/// never a store" rule -- see `SkcodeJobRun`'s doc comment for the other
/// half of that rule).
class SkcodeJobsListStore {
  SkcodeJobsListStore({
    required SkcodeApiClient apiClient,
    required Future<String?> Function() mintToken,
    this.pollInterval = const Duration(seconds: 30),
  }) : _apiClient = apiClient,
       _mintToken = mintToken;

  final SkcodeApiClient _apiClient;
  final Future<String?> Function() _mintToken;
  final Duration pollInterval;

  final _controller = StreamController<SkcodeJobsPoll>.broadcast();

  Stream<SkcodeJobsPoll> get jobs => _controller.stream;

  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  List<SkcodeJobRun> _lastKnown = const [];
  bool _everSucceeded = false;

  bool get isPolling => _polling;

  /// Start polling immediately (fires one fetch right away, then every
  /// [pollInterval]). Idempotent: calling while already polling is a no-op.
  void startPolling() {
    if (_polling || _disposed) return;
    _polling = true;
    unawaited(_poll());
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  /// Stop polling (e.g. the Jobs section scrolled out of view / the rail
  /// closed). Idempotent.
  void stopPolling() {
    _polling = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_disposed) return;
    final token = await _mintToken();
    if (token == null) {
      _emit(failed: true); // tokenless: caller renders the gated/degrade state.
      return;
    }
    try {
      final list = await _apiClient.listJobs(token: token);
      _lastKnown = list;
      _everSucceeded = true;
      _emit(failed: false);
    } catch (_) {
      // One missed tick degrades to the failure marker -- never an
      // exception reaching the widget tree; the section renders its own
      // "unavailable" (never-succeeded) or last-known-good (succeeded
      // before) state from it.
      _emit(failed: true);
    }
  }

  void _emit({required bool failed}) {
    if (_disposed || _controller.isClosed) return;
    _controller.add(
      SkcodeJobsPoll(jobs: _lastKnown, everSucceeded: _everSucceeded, failed: failed),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    await _controller.close();
  }
}
