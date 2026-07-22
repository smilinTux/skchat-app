// Native operator-token seam: an in-memory cache.
//
// The operator token (the funnel-bypass secret) is only needed in-session, at
// the moment of device enrollment: the user types it, then [openEnrollWindow]
// reads it immediately to authenticate the enroll/open request. Once the device
// is enrolled, it authenticates with its device KEY (persisted by
// guest_key_store), not this token, so persisting the token across app restarts
// is unnecessary here. Web keeps it in localStorage; native holds it in memory.

String? _token;

String? operatorToken() => _token;

void setOperatorToken(String? value) =>
    _token = (value == null || value.isEmpty) ? null : value;
