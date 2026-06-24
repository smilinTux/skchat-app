import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// PqDmCodec interop gate (PQC-MIGRATION Q5).
///
/// Proves the Dart codec is byte-for-byte interoperable with the Python daemon's
/// `skcomms/pqdm.py`:
///   1. Dart OPENS a Python-pqdm-sealed blob  (Python → Dart).
///   2. Python OPENS a Dart-sealed blob        (Dart → Python), verified by the
///      sibling `verify_dart_vector.py` (the test writes the Dart blob; a CI/dev
///      step runs the Python verifier — see the test that emits `dart_sealed.json`).
///   3. AAD bytes match the Python `downgrade_lock_aad` exactly.
///   4. Self round-trip (Dart seal → Dart open).
///   5. Downgrade-lock: a wrong-suite open fails (DowngradeDetected).
///
/// Requires the native liboqs backend (set LD_LIBRARY_PATH / SK_PQC_LIBOQS). If
/// the PQ backend is unavailable the KEM-dependent tests are skipped cleanly so
/// the suite still passes on a machine without liboqs.
void main() {
  final vectorFile = File('test/pqc_vectors/python_sealed.json');

  bool kemAvailable() {
    try {
      // Touch the native backend; throws if liboqs is missing.
      HybridKemImpl();
      return true;
    } catch (_) {
      return false;
    }
  }

  group('PqDmCodec AAD (pure, no KEM)', () {
    test('matches Python downgrade_lock_aad byte-for-byte', () {
      if (!vectorFile.existsSync()) {
        markTestSkipped('python_sealed.json not generated');
        return;
      }
      final v = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;
      final aad = PqDmCodec.downgradeLockAad(
        v['suite'] as String,
        sender: v['sender'] as String,
        recipient: v['recipient'] as String,
      );
      final expected = base64.decode(v['aad_b64'] as String);
      expect(aad, equals(expected));
    });

    test('canonical key order + compact separators (sorted keys)', () {
      final aad = utf8.decode(
        PqDmCodec.downgradeLockAad('x25519-mlkem768',
            sender: 'lumina', recipient: 'chef'),
      );
      expect(
        aad,
        '{"negotiated_suite":"x25519-mlkem768",'
        '"recipient":"chef","sender":"lumina","v":1}',
      );
    });
  });

  group('PqDmCodec interop (needs liboqs)', () {
    test('opens a Python-pqdm-sealed blob (Python → Dart)', () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      if (!vectorFile.existsSync()) {
        markTestSkipped('python_sealed.json not generated');
        return;
      }
      final v = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;
      final codec = PqDmCodec();
      final priv = _hex(v['recipient_private_hex'] as String);

      // Open via the raw blob …
      final sealed = _hex(v['sealed_hex'] as String);
      final clearRaw = await codec.openRaw(
        sealed,
        priv,
        sender: v['sender'] as String,
        recipient: v['recipient'] as String,
        expectedSuite: v['suite'] as String,
      );
      expect(utf8.decode(clearRaw), v['plaintext']);

      // … and via the full `pqdm1:` token (the wire form in `content`).
      final clearTok = await codec.openToken(
        v['token'] as String,
        priv,
        sender: v['sender'] as String,
        recipient: v['recipient'] as String,
      );
      expect(utf8.decode(clearTok), v['plaintext']);
    });

    test('Dart seal → Dart open round-trip', () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final codec = PqDmCodec();
      final kp = await HybridKemImpl().generateKeyPair();
      const msg = 'round-trip 🔐 ünïcode ✓';
      final token = await codec.sealToken(
        Uint8List.fromList(utf8.encode(msg)),
        kp.publicKey,
        sender: 'chef',
        recipient: 'lumina',
      );
      expect(token.startsWith('pqdm1:x25519-mlkem768:'), isTrue);
      final clear = await codec.openToken(
        token,
        kp.privateKey,
        sender: 'chef',
        recipient: 'lumina',
      );
      expect(utf8.decode(clear), msg);
    });

    test('emits dart_sealed.json for Python → verify (Dart → Python gate)',
        () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      // Use the SAME recipient keypair the Python vector published, so the
      // Python verifier can open our blob with the private key it already holds.
      if (!vectorFile.existsSync()) {
        markTestSkipped('python_sealed.json not generated');
        return;
      }
      final v = jsonDecode(vectorFile.readAsStringSync()) as Map<String, dynamic>;
      final codec = PqDmCodec();
      const sender = 'chef';
      const recipient = 'lumina';
      const msg = 'sealed by Dart → opened by pqdm.py 🔐';
      final token = await codec.sealToken(
        Uint8List.fromList(utf8.encode(msg)),
        _hex(v['recipient_public_hex'] as String),
        sender: sender,
        recipient: recipient,
      );
      final out = {
        'suite': 'x25519-mlkem768',
        'sender': sender,
        'recipient': recipient,
        'plaintext': msg,
        'recipient_private_hex': v['recipient_private_hex'],
        'token': token,
      };
      File('test/pqc_vectors/dart_sealed.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
      expect(token.contains('pqdm1:'), isTrue);
    });

    test('downgrade-lock: opening with a wrong expected suite fails', () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final codec = PqDmCodec();
      final kp = await HybridKemImpl().generateKeyPair();
      final sealed = await codec.sealRaw(
        Uint8List.fromList(utf8.encode('secret')),
        kp.publicKey,
        sender: 'chef',
        recipient: 'lumina',
      );
      // Recipient believes a DIFFERENT suite was negotiated → AAD mismatch.
      await expectLater(
        codec.openRaw(
          sealed,
          kp.privateKey,
          sender: 'chef',
          recipient: 'lumina',
          expectedSuite: 'x25519-pgp-wrap-v1',
        ),
        throwsA(isA<DowngradeDetected>()),
      );
    });
  });
}

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
