// Non-web stub for GuestIdentity. There is no WebCrypto / localStorage off the
// browser, so this keeps an in-memory ephemeral keypair surrogate. It exists so
// the app compiles on non-web targets and so unit tests can drive the join flow
// without a browser. Production guest access is web-only (the app is a web build
// — see daemon_proxy.py header).

import 'dart:convert';
import 'dart:math';

import 'guest_identity.dart';

GuestIdentity createGuestIdentity() => _StubGuestIdentity();

class _StubGuestIdentity implements GuestIdentity {
  String? _pub;
  String? _fp;

  @override
  Future<bool> hasCached() async => _pub != null;

  @override
  Future<GuestKeypair> ensure() async {
    if (_pub != null) {
      return GuestKeypair(publicKeyB64: _pub!, fingerprint: _fp!);
    }
    final rnd = Random.secure();
    final raw = List<int>.generate(32, (_) => rnd.nextInt(256));
    _pub = base64Encode(raw);
    _fp = _pub!.replaceAll(RegExp(r'[^a-f0-9]'), '0').padRight(16, '0').substring(0, 16);
    return GuestKeypair(publicKeyB64: _pub!, fingerprint: _fp!);
  }

  @override
  Future<String> sign(String data) async {
    // Deterministic non-crypto placeholder signature (off-web only).
    return base64Encode(utf8.encode('stub-sig:${data.hashCode}'));
  }

  @override
  Future<void> clear() async {
    _pub = null;
    _fp = null;
  }
}
