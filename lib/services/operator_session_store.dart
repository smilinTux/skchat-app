// Platform seam for the MINTED operator SESSION token (the short-lived
// bearer JWT produced by OperatorSessionService's challenge-response
// handshake, attached as `Authorization: Bearer <token>` by SKCommsClient's
// interceptor). Stored under its OWN key, DISTINCT from operator_token.dart's
// `sk_operator_token` key.
//
// Those two credentials are NOT the same thing and must never share a slot:
// - `operator_token.dart` holds the manually-pasted SKCHAT_GUEST_OPERATOR_TOKEN
//   raw secret (set via the mode-C dialog), sent as the `X-Operator-Token`
//   header by mode_c_service.dart / guest_group_service.dart.
// - this seam holds the auto-minted session JWT from the device-key
//   handshake.
// If OperatorSessionService defaulted to the `operator_token` slot, a
// successful handshake would overwrite the user's pasted operator token, and
// `clearSession()` (run on a 401) would wipe it entirely. Stored in web
// localStorage; a no-op on native (which reaches operator routes over the
// tailnet and needs no token).
import 'operator_session_store_stub.dart'
    if (dart.library.io) 'operator_session_store_io.dart'
    if (dart.library.html) 'operator_session_store_web.dart' as impl;

/// The stored operator SESSION token, or null when unset.
String? operatorSessionToken() => impl.operatorSessionToken();

/// Persist (or clear, when null/empty) the operator SESSION token.
void setOperatorSessionToken(String? value) =>
    impl.setOperatorSessionToken(value);
