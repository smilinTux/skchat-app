import "dart:async";

import "skcode_api_client.dart";

/// The two ways a poll can fail to produce a list, card C-19: unauthorized
/// (no usable token) or unreachable (skcode-hostd itself did not answer). A
/// poll that genuinely succeeded with zero rows is not a failure at all --
/// see [SkcodeSessionsPoll.everSucceeded] and [SkcodeSessionsPoll.sessions],
/// which the rail reads instead to render that third, distinct state.
///
/// [unauthorized] covers BOTH halves of "the operator doesn't have access":
/// [SkcodeSessionsListStore._mintToken] resolving `null` (a token was never
/// minted -- there is nothing to send) and skcode-hostd answering 401 via
/// [SkcodeUnauthorizedException] (a token was minted but rejected). Both
/// point the operator at the same next action -- sign in again -- so they
/// share one value rather than being split into a fourth state nobody would
/// react to differently.
enum SkcodeSessionsFailureKind {
  /// The most recent poll attempt did not fail (or none has run yet).
  none,

  /// No usable token reached skcode-hostd: never minted, or minted and
  /// rejected (401). The operator's next action is the same either way --
  /// sign in again.
  unauthorized,

  /// skcode-hostd did not answer: connection refused, DNS failure, timeout,
  /// the funnel down, or any other non-401 transport/HTTP failure.
  unreachable,
}

/// One poll's outcome for [SkcodeSessionsListStore]'s stream: either a fresh
/// list from a successful `GET /skcode/api/v1/sessions` call, or a failure
/// marker carrying forward the last successfully known list.
///
/// Mirrors [SkcodeJobsPoll]'s shape and doc comment (card C-8's "never
/// fetched" vs "fetched, zero rows" split) with one addition: card C-19
/// needs "never fetched" itself split into WHY -- unauthorized vs
/// unreachable -- because "you are not authorized" and "the host is
/// unreachable" point the operator at completely different next actions,
/// and both used to render as the same generic empty state.
class SkcodeSessionsPoll {
  const SkcodeSessionsPoll({
    required this.sessions,
    required this.everSucceeded,
    required this.failureKind,
  });

  final List<SkcodeSessionSummary> sessions;

  /// True once at least one poll has ever returned successfully.
  final bool everSucceeded;

  /// The MOST RECENT poll attempt's outcome ([SkcodeSessionsFailureKind.none]
  /// when it succeeded). [sessions] still carries the last successful list
  /// when one exists, so a transient failure AFTER a prior success never
  /// blanks an otherwise-working rail: the rail only renders an error state
  /// INSTEAD OF the list when [everSucceeded] is false. Matches
  /// `SkcodeSessionsListStore`'s longstanding "one missed tick is not an
  /// error state" rule, now made visible to the widget instead of swallowed
  /// silently.
  final SkcodeSessionsFailureKind failureKind;
}

/// Polls `GET /skcode/api/v1/sessions` at [pollInterval] (spec 4.3: "poll at
/// 15s while the rail is visible; cheap") while [startPolling] has been
/// called and [stopPolling] has not. A plain Dart class for the same reason
/// as `SkcodeSessionStore`: unit-testable with a fake clock, no
/// `ProviderContainer` needed. See `skcode_providers.dart` for the Riverpod
/// wrapper that starts/stops polling as the sessions rail mounts/unmounts.
class SkcodeSessionsListStore {
  SkcodeSessionsListStore({
    required SkcodeApiClient apiClient,
    required Future<String?> Function() mintToken,
    this.pollInterval = const Duration(seconds: 15),
  }) : _apiClient = apiClient,
       _mintToken = mintToken;

  final SkcodeApiClient _apiClient;
  final Future<String?> Function() _mintToken;
  final Duration pollInterval;

  final _controller = StreamController<SkcodeSessionsPoll>.broadcast();

  /// Every poll's outcome, success or failure alike (card C-19): a failed
  /// poll is no longer skipped silently -- it is emitted as a
  /// [SkcodeSessionsPoll] carrying [SkcodeSessionsPoll.failureKind] so the
  /// rail can render the honest reason instead of guessing from silence.
  /// The last successfully known list rides along on every emission
  /// ([SkcodeSessionsPoll.sessions]), so this is still "cheap" and never a
  /// source of flicker: a transient failure after success does not change
  /// what the rail shows.
  Stream<SkcodeSessionsPoll> get sessions => _controller.stream;

  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  List<SkcodeSessionSummary> _lastKnown = const [];
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

  /// Stop polling (e.g. the rail scrolled out of view / the pane closed).
  /// Idempotent.
  void stopPolling() {
    _polling = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_disposed) return;
    final token = await _mintToken();
    if (token == null) {
      // Tokenless: never minted, so there is nothing to send. Same operator
      // message as a 401 below -- see SkcodeSessionsFailureKind.unauthorized.
      _emit(SkcodeSessionsFailureKind.unauthorized);
      return;
    }
    try {
      final list = await _apiClient.listSessions(token: token);
      _lastKnown = list;
      _everSucceeded = true;
      _emit(SkcodeSessionsFailureKind.none);
    } on SkcodeUnauthorizedException {
      // Minted but rejected: skcode-hostd answered 401.
      _emit(SkcodeSessionsFailureKind.unauthorized);
    } catch (_) {
      // Any other transport/HTTP failure -- connection refused, DNS,
      // timeout, funnel down. Never an exception reaching the widget tree;
      // the rail renders its own unreachable (never-succeeded) or
      // last-known-good (succeeded before) state from it.
      _emit(SkcodeSessionsFailureKind.unreachable);
    }
  }

  void _emit(SkcodeSessionsFailureKind failureKind) {
    if (_disposed || _controller.isClosed) return;
    _controller.add(
      SkcodeSessionsPoll(
        sessions: _lastKnown,
        everSucceeded: _everSucceeded,
        failureKind: failureKind,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    await _controller.close();
  }
}
