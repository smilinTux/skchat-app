import 'package:web/web.dart' as web;

// Distinct key from operator_token.dart's `sk_operator_token`; see
// operator_session_store.dart for why these must never share a slot.
const _key = 'sk_operator_session';

String? operatorSessionToken() {
  try {
    final v = web.window.localStorage.getItem(_key);
    return (v == null || v.isEmpty) ? null : v;
  } catch (_) {
    return null;
  }
}

void setOperatorSessionToken(String? value) {
  try {
    if (value == null || value.isEmpty) {
      web.window.localStorage.removeItem(_key);
    } else {
      web.window.localStorage.setItem(_key, value);
    }
  } catch (_) {}
}
