// Platform seam for the operator token (used to reach operator-gated routes
// over the public Funnel). Stored in web localStorage; a no-op on native (which
// reaches operator routes over the tailnet and needs no token).
import 'operator_token_stub.dart'
    if (dart.library.io) 'operator_token_io.dart'
    if (dart.library.html) 'operator_token_web.dart' as impl;

/// The stored operator token, or null when unset.
String? operatorToken() => impl.operatorToken();

/// Persist (or clear, when null/empty) the operator token.
void setOperatorToken(String? value) => impl.setOperatorToken(value);
