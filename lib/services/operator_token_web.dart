import 'package:web/web.dart' as web;

const _key = 'sk_operator_token';

String? operatorToken() {
  try {
    final v = web.window.localStorage.getItem(_key);
    return (v == null || v.isEmpty) ? null : v;
  } catch (_) {
    return null;
  }
}

void setOperatorToken(String? value) {
  try {
    if (value == null || value.isEmpty) {
      web.window.localStorage.removeItem(_key);
    } else {
      web.window.localStorage.setItem(_key, value);
    }
  } catch (_) {}
}
