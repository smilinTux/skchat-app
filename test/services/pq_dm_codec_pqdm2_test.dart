import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// pqdm2 multi-recipient (fanout) interop gate for the Dart codec.
///
/// Proves the Dart [PqDmCodec.buildPqdm2] / [PqDmCodec.openPqdm2] are
/// byte-for-byte interoperable with the Python `skcomms/pqdm.py`
/// `seal_multi`/`open_multi`:
///   1. Python seal -> Dart open (reads the committed
///      `test/fixtures/pqdm2_from_python.json`; every slot opens).
///   2. Dart seal -> Dart open round-trip (2-device fanout, each slot opens,
///      a non-recipient gets null).
///   3. Dart seal -> Python open: emits `test/fixtures/pqdm2_from_dart.json`
///      which the committed `skcomms/tests/test_pqdm2_interop.py` opens.
///
/// Requires the native liboqs backend. If it is unavailable the KEM tests are
/// skipped cleanly (the interop gate is run on a box that has liboqs).
void main() {
  final pyFixture = File('test/fixtures/pqdm2_from_python.json');

  bool kemAvailable() {
    try {
      HybridKemImpl();
      return true;
    } catch (_) {
      return false;
    }
  }

  group('pqdm2 interop (needs liboqs)', () {
    test('opens a pqdm2 token sealed by the Python lib (every slot)', () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final f =
          jsonDecode(pyFixture.readAsStringSync()) as Map<String, dynamic>;
      final codec = PqDmCodec();

      // Primary slot via the plan's top-level field names.
      final pt = await codec.openPqdm2(
        f['token'] as String,
        myKeyId: f['key_id'] as String,
        myPrivate: _hex(f['private_hex'] as String),
        sender: f['sender'] as String,
        recipientId: f['recipient'] as String,
      );
      expect(pt, isNotNull);
      expect(utf8.decode(pt!), f['body'] as String);

      // Every slot in the fixture must open to the same body.
      for (final slot in (f['slots'] as List).cast<Map<String, dynamic>>()) {
        final clear = await codec.openPqdm2(
          f['token'] as String,
          myKeyId: slot['key_id'] as String,
          myPrivate: _hex(slot['private_hex'] as String),
          sender: f['sender'] as String,
          recipientId: f['recipient'] as String,
        );
        expect(clear, isNotNull);
        expect(utf8.decode(clear!), f['body'] as String);
      }
    });

    test('a pqdm2 token built in Dart round-trips in Dart', () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final codec = PqDmCodec();
      final a = await HybridKemImpl().generateKeyPair();
      final b = await HybridKemImpl().generateKeyPair();
      final aKid = _bytesToHex(a.publicKey).substring(0, 16);
      final bKid = _bytesToHex(b.publicKey).substring(0, 16);
      const body = 'round-trip fanout ünïcode ok';

      final token = await codec.buildPqdm2(
        Uint8List.fromList(utf8.encode(body)),
        [
          Pqdm2Recipient(keyId: aKid, hybridPublicKey: a.publicKey),
          Pqdm2Recipient(keyId: bKid, hybridPublicKey: b.publicKey),
        ],
        sender: 'lumina',
        recipientId: 'chef',
      );
      expect(token.startsWith('pqdm2:'), isTrue);

      final openedA = await codec.openPqdm2(token,
          myKeyId: aKid,
          myPrivate: a.privateKey,
          sender: 'lumina',
          recipientId: 'chef');
      final openedB = await codec.openPqdm2(token,
          myKeyId: bKid,
          myPrivate: b.privateKey,
          sender: 'lumina',
          recipientId: 'chef');
      expect(utf8.decode(openedA!), body);
      expect(utf8.decode(openedB!), body);

      // A device whose key_id is not in the header has no slot -> null.
      final c = await HybridKemImpl().generateKeyPair();
      final openedC = await codec.openPqdm2(token,
          myKeyId: 'deadbeefdeadbeef',
          myPrivate: c.privateKey,
          sender: 'lumina',
          recipientId: 'chef');
      expect(openedC, isNull);
    });

    test('emits pqdm2_from_dart.json for the Python reverse-interop test',
        () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final codec = PqDmCodec();
      final a = await HybridKemImpl().generateKeyPair();
      final b = await HybridKemImpl().generateKeyPair();
      final aKid = _bytesToHex(a.publicKey).substring(0, 16);
      final bKid = _bytesToHex(b.publicKey).substring(0, 16);
      const sender = 'lumina';
      const recipient = 'chef';
      const body = 'sealed by Dart, opened by pqdm.py';

      final token = await codec.buildPqdm2(
        Uint8List.fromList(utf8.encode(body)),
        [
          Pqdm2Recipient(keyId: aKid, hybridPublicKey: a.publicKey),
          Pqdm2Recipient(keyId: bKid, hybridPublicKey: b.publicKey),
        ],
        sender: sender,
        recipientId: recipient,
      );

      final out = {
        'token': token,
        'sender': sender,
        'recipient': recipient,
        'body': body,
        'key_id': aKid,
        'private_hex': _bytesToHex(a.privateKey),
        'slots': [
          {'key_id': aKid, 'private_hex': _bytesToHex(a.privateKey)},
          {'key_id': bKid, 'private_hex': _bytesToHex(b.privateKey)},
        ],
      };
      File('test/fixtures/pqdm2_from_dart.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
      expect(token.startsWith('pqdm2:'), isTrue);
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

String _bytesToHex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
