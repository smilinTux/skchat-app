import "dart:async";

import "skcode_api_client.dart";

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

  final _controller =
      StreamController<List<SkcodeSessionSummary>>.broadcast();

  /// Each successful poll's result. A failed poll (no token, transport
  /// error) is skipped silently and the previous list stays displayed —
  /// polling is "cheap" per the spec, not a source of flicker.
  Stream<List<SkcodeSessionSummary>> get sessions => _controller.stream;

  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

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
    if (token == null) return; // tokenless: caller renders the gated state.
    try {
      final list = await _apiClient.listSessions(token: token);
      if (!_disposed && !_controller.isClosed) _controller.add(list);
    } catch (_) {
      // One missed tick is not an error state; the next poll tries again.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    await _controller.close();
  }
}
