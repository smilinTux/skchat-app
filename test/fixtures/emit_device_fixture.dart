// test/fixtures/emit_device_fixture.dart
// Emits one JSON fixture line for the Python wire-compat test. Run:
//   dart run test/fixtures/emit_device_fixture.dart
import 'dart:convert';
import 'package:skchat/services/guest_identity_io.dart';
import 'package:skchat/services/guest_key_store.dart';

class _Mem implements GuestKeyStore {
  final Map<String, String> _m = {};
  @override
  Future<void> delete(String k) async => _m.remove(k);
  @override
  Future<String?> read(String k) async => _m[k];
  @override
  Future<void> write(String k, String v) async => _m[k] = v;
}

Future<void> main() async {
  final id = NativeGuestIdentity(store: _Mem());
  final kp = await id.ensure();
  const payload = '{"device_fp":"x","nonce":"wire-compat-nonce"}';
  final sig = await id.sign(payload);
  // ignore: avoid_print
  print(jsonEncode({
    'pubkey_b64': kp.publicKeyB64,
    'fingerprint': kp.fingerprint,
    'payload': payload,
    'sig_b64': sig,
  }));
}
