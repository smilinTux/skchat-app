// Native operator SESSION-token seam: an in-memory cache.
//
// On startup a native operator device re-mints its short-lived session JWT via
// [OperatorSessionService.ensureSession] (a device-key challenge-response
// against the already-enrolled key), so persisting the JWT across restarts is
// only an optimization, not required for correctness. Web keeps it in
// localStorage; native holds it in memory and simply re-handshakes on launch.

String? _session;

String? operatorSessionToken() => _session;

void setOperatorSessionToken(String? value) =>
    _session = (value == null || value.isEmpty) ? null : value;
