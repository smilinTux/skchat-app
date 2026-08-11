import "dart:async";
import "dart:convert";
import "dart:math";

import "skcode_api_client.dart";
import "skcode_event.dart";
import "skcode_event_merge.dart";
import "skcode_ws_transport.dart";

/// Lifecycle of one [SkcodeSessionStore]'s WS connection.
enum SkcodeConnectionPhase {
  /// [SkcodeSessionStore.start] has not been called yet.
  idle,

  /// The first connection attempt is in flight.
  connecting,

  /// The WS stream is live.
  connected,

  /// The connection dropped and a reconnect is scheduled or in flight.
  reconnecting,

  /// Gave up: no token available, or a 401/1008 survived the single re-mint
  /// retry. Surfaced visibly per spec 4.2 ("re-mint once, retry, then fail
  /// visibly. Do not retry in a loop.").
  failed,
}

/// Immutable snapshot a [SkcodeSessionStore] emits on every change.
///
/// [events] is always the fully merged (live + archive), deduped
/// (`sid, seq, ts`), ascending-(ts, seq)-sorted, live-window-capped result —
/// exactly what a transcript/raw-rail consumer (card C-4) renders directly.
class SkcodeSessionState {
  const SkcodeSessionState({
    this.phase = SkcodeConnectionPhase.idle,
    this.events = const [],
    this.error,
  });

  final SkcodeConnectionPhase phase;
  final List<SkcodeEvent> events;

  /// Non-null only in [SkcodeConnectionPhase.failed].
  final String? error;

  SkcodeSessionState copyWith({
    SkcodeConnectionPhase? phase,
    List<SkcodeEvent>? events,
    String? error,
    bool clearError = false,
  }) {
    return SkcodeSessionState(
      phase: phase ?? this.phase,
      events: events ?? this.events,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Jittered exponential backoff: `base * 2^(attempt-1)`, capped at [max],
/// plus up to 30% random jitter so a fleet of reconnecting clients does not
/// thunder the daemon in lockstep.
Duration defaultSkcodeBackoff(
  int attempt, {
  Duration base = const Duration(milliseconds: 500),
  Duration max = const Duration(seconds: 30),
  Random? random,
}) {
  final rand = random ?? Random();
  final exp = base * pow(2, (attempt - 1).clamp(0, 20)).toDouble();
  final capped = exp > max ? max : exp;
  final jitterFactor = 1.0 + rand.nextDouble() * 0.3;
  final jittered = capped * jitterFactor;
  return jittered > max * 1.3 ? Duration(milliseconds: (max.inMilliseconds * 1.3).round()) : jittered;
}

/// One session's transport + merge/dedup state machine (card C-3, spec
/// 4.2/4.3/5.2). One instance per open session.
///
/// Owns:
///  * the WS tail (`WS /skcode/api/v1/sessions/{sid}/stream?token=...`,
///    jittered backoff reconnect),
///  * the archive page fetch (`GET .../events?before_seq=&limit=`) re-run on
///    every reconnect and merged with the live window,
///  * the live-window cap (3000 events, Buzz's `MAX_OBSERVER_EVENTS`),
///  * the HTTP-401 / WS-1008 re-mint-once-then-fail-visibly rule (spec 4.2).
///
/// Deliberately a plain Dart class (not a Riverpod `Notifier` itself) so its
/// state machine is unit-testable with fakes and no `ProviderContainer`; see
/// `skcode_providers.dart` for the thin Riverpod wrapper.
class SkcodeSessionStore {
  SkcodeSessionStore({
    required this.sid,
    required SkcodeApiClient apiClient,
    required Future<String?> Function() mintToken,
    required void Function() onAuthRejected,
    required SkcodeWsTransport Function(Uri uri) connectTransport,
    required Uri Function(String sid, String token) buildWsUri,
    int maxLiveEvents = kMaxLiveSkcodeEvents,
    Duration Function(int attempt)? backoffFor,
    int archivePageLimit = 200,
  }) : _apiClient = apiClient,
       _mintToken = mintToken,
       _onAuthRejected = onAuthRejected,
       _connectTransport = connectTransport,
       _buildWsUri = buildWsUri,
       _maxLiveEvents = maxLiveEvents,
       _backoffFor = backoffFor ?? defaultSkcodeBackoff,
       _archivePageLimit = archivePageLimit;

  final String sid;
  final SkcodeApiClient _apiClient;
  final Future<String?> Function() _mintToken;

  /// Invoked exactly once per auth-rejection cycle (an archive-fetch 401 or
  /// a WS close 1008), so the host can drop its cached audience token and
  /// force the next [mintToken] to genuinely re-mint (card C-3b: this is the
  /// callback the architecture spec calls `onAuthRejected`, injected at the
  /// composition root, module contract standard section 3.1).
  final void Function() _onAuthRejected;
  final SkcodeWsTransport Function(Uri uri) _connectTransport;
  final Uri Function(String sid, String token) _buildWsUri;
  final int _maxLiveEvents;
  final Duration Function(int attempt) _backoffFor;
  final int _archivePageLimit;

  final _stateController = StreamController<SkcodeSessionState>.broadcast();
  Stream<SkcodeSessionState> get states => _stateController.stream;

  SkcodeSessionState _state = const SkcodeSessionState();
  SkcodeSessionState get state => _state;

  List<SkcodeEvent> _live = const [];
  List<SkcodeEvent> _archived = const [];

  int _attempt = 0;
  bool _remintedThisWsCycle = false;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _started = false;

  /// Number of WS (re)connect attempts made so far. Exposed for tests.
  int get reconnectAttempts => _attempt;

  /// Begin: load the archive window, then open the WS tail. Safe to call at
  /// most once (later calls are no-ops); use a fresh instance per session
  /// mount.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _loadArchiveAndMerge();
    if (_disposed) return;
    await _connect();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    if (!_stateController.isClosed) await _stateController.close();
  }

  // ---- archive ------------------------------------------------------------

  Future<void> _loadArchiveAndMerge() async {
    var reminted = false;
    while (true) {
      final token = await _mintToken();
      if (token == null) {
        _emit(
          _state.copyWith(
            phase: SkcodeConnectionPhase.failed,
            error: "no audience token available",
          ),
        );
        return;
      }
      try {
        final page = await _apiClient.fetchEventsPage(
          sid,
          token: token,
          limit: _archivePageLimit,
        );
        _archived = page;
        _recomputeMerged();
        return;
      } on SkcodeUnauthorizedException {
        if (reminted) {
          // Archive is best-effort on an ongoing connection: do not fail the
          // whole store over a stubborn archive 401, just stop trying this
          // round. The WS 1008 path is the authoritative visible failure.
          return;
        }
        reminted = true;
        _onAuthRejected();
        continue;
      } on SkcodeApiException {
        // Transient/non-auth failure: archive stays whatever it was.
        return;
      }
    }
  }

  // ---- WS -------------------------------------------------------------------

  Future<void> _connect() async {
    if (_disposed) return;
    _emit(
      _state.copyWith(
        phase: _attempt == 0
            ? SkcodeConnectionPhase.connecting
            : SkcodeConnectionPhase.reconnecting,
      ),
    );

    final token = await _mintToken();
    if (token == null) {
      _emit(
        _state.copyWith(
          phase: SkcodeConnectionPhase.failed,
          error: "no audience token available",
        ),
      );
      return;
    }

    final uri = _buildWsUri(sid, token);
    final transport = _connectTransport(uri);
    try {
      await transport.ready;
    } catch (_) {
      // Fire-and-forget: [_scheduleReconnect] only SCHEDULES a timer and
      // returns immediately. It must never be awaited here — awaiting it
      // would chain this whole call (and therefore `start()`, on the very
      // first connect) through however many backoff cycles it takes to
      // eventually succeed, turning a "kick off the connection" call into a
      // "block until connected" call.
      _scheduleReconnect();
      return;
    }
    if (_disposed) {
      await transport.close();
      return;
    }

    _attempt = 0;
    // NOTE: the re-mint budget is deliberately NOT reset here. A successful
    // handshake right after a 1008-triggered re-mint retry does not yet
    // prove the incident is over (skcode-hostd's own close-1008 path closes
    // AFTER a completed handshake, see `daemon.py::stream`, so "handshake ok"
    // and "then immediately 1008 again" look identical from here). The
    // budget resets in `_scheduleReconnect` instead: that only runs for a
    // NEW reconnect cycle triggered by a non-auth disconnect, which is the
    // meaningful "this incident is over" signal.
    _emit(_state.copyWith(phase: SkcodeConnectionPhase.connected, clearError: true));

    await _sub?.cancel();
    _sub = transport.stream.listen(
      _onFrame,
      onDone: () => _onClosed(transport.closeCode),
      onError: (_) => _onClosed(transport.closeCode),
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic raw) {
    Map<String, dynamic>? json;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return;
      }
    } else if (raw is Map) {
      json = Map<String, dynamic>.from(raw);
    }
    if (json == null) return;

    final event = SkcodeEvent.fromJson(json);
    final appended = [..._live, event]
      ..sort((a, b) {
        final tsCmp = a.ts.compareTo(b.ts);
        return tsCmp != 0 ? tsCmp : a.seq.compareTo(b.seq);
      });
    _live = capLiveSkcodeWindow(appended, max: _maxLiveEvents);
    _recomputeMerged();
  }

  Future<void> _onClosed(int? code) async {
    if (_disposed) return;
    await _sub?.cancel();
    _sub = null;

    // 1008 = policy violation, skcode-hostd's shape for "bad/expired wire
    // token" (spec 4.2). Re-mint ONCE, retry immediately; if it happens
    // again in the SAME cycle (i.e. the fresh token was rejected too), stop
    // and surface an error rather than looping.
    if (code == 1008) {
      if (!_remintedThisWsCycle) {
        _remintedThisWsCycle = true;
        _onAuthRejected();
        await _connect();
        return;
      }
      _emit(
        _state.copyWith(
          phase: SkcodeConnectionPhase.failed,
          error: "unauthorized (WS 1008) after one re-mint retry",
        ),
      );
      return;
    }

    // Any other close (daemon restart, network blip, normal server close):
    // an honest reconnect with jittered backoff. On reconnect, re-fetch the
    // archive window and merge (spec 4.3) — this is what makes a daemon
    // restart mid-stream safe: the archive may now hold events the live
    // window's seq counter reset past.
    _scheduleReconnect();
  }

  /// Schedules the next reconnect attempt and returns immediately: this is a
  /// background timer, never something a caller awaits to completion (the
  /// eventual reconnect may itself fail and re-schedule again, backoff after
  /// backoff — a caller awaiting that chain would block for as long as the
  /// daemon stays down, see the `_connect` doc comment on its catch clause).
  void _scheduleReconnect() {
    if (_disposed) return;
    _attempt += 1;
    // A NEW reconnect cycle (triggered by a non-auth disconnect: daemon
    // restart, network blip, normal server close) is the "this incident is
    // over" signal that resets the 1008 re-mint budget, so a long-lived
    // session that later hits a genuinely new auth problem gets its own
    // single re-mint chance rather than being permanently stuck failed from
    // an unrelated 1008 hours earlier.
    _remintedThisWsCycle = false;
    _emit(_state.copyWith(phase: SkcodeConnectionPhase.reconnecting));
    final delay = _backoffFor(_attempt);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (_disposed) return;
      await _loadArchiveAndMerge();
      await _connect();
    });
  }

  // ---- merge ----------------------------------------------------------------

  void _recomputeMerged() {
    // The 3000 cap applies to [_live] alone (enforced in [_onFrame] as each
    // frame arrives). The MERGED view is deliberately never re-capped here:
    // the archive is uncapped and paged (spec 5.3, "archive paging extends
    // beyond it" — AC5), so a merge that re-applied the live cap would
    // truncate exactly the archived history paging exists to surface.
    final merged = mergeSkcodeEventWindows(_live, _archived);
    _emit(_state.copyWith(events: merged));
  }

  void _emit(SkcodeSessionState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }
}
