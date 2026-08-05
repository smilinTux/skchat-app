import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// PQC multi-device fanout (Phase 1), Task 10 - receiver opens pqdm2 (app).
///
/// [PqConversationService.openIncomingDetailed] learns the `pqdm2:` fanout
/// envelope: it selects THIS device's own slot (its published `key_id`) and
/// opens it via [PqDmCodec.openPqdm2]. A token that carries no slot for this
/// device returns the graceful locked placeholder (opened=false), matching the
/// existing pqLocked behavior, NOT a crash. The `pqdm1:` path is unchanged
/// (covered by pq_conversation_service_test.dart).
class _RealKeyPrekeyService implements PqPrekeyService {
  _RealKeyPrekeyService({
    required this.keyIdValue,
    required this.privValue,
    this.hasKey = true,
  });

  String? keyIdValue;
  Uint8List? privValue;
  bool hasKey;

  @override
  Future<bool> ensureKeyPair() async => hasKey;

  @override
  String? get keyId => keyIdValue;

  @override
  Uint8List? get privateKey => privValue;

  // A fanout token with no slot for this device makes openIncomingDetailed fire
  // the fire-and-forget decrypt-failure NACK
  // (PqConversationService._reportDecryptFailure ->
  // reportDecryptFailure(localShort)). Implement the current real signature so
  // that call resolves through the double instead of throwing NoSuchMethodError.
  @override
  Future<bool> reportDecryptFailure(String peerShort, {String? messageId}) async =>
      false;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _bytesToHex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool kemAvailable() {
    try {
      HybridKemImpl();
      return true;
    } catch (_) {
      return false;
    }
  }

  group('openIncomingDetailed pqdm2 (Task 10, needs liboqs)', () {
    test('selects this device OWN slot from a fanout token and opens it',
        () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final codec = PqDmCodec();
      final me = await HybridKemImpl().generateKeyPair();
      final other = await HybridKemImpl().generateKeyPair();
      final myKid = _bytesToHex(me.publicKey).substring(0, 16);
      final otherKid = _bytesToHex(other.publicKey).substring(0, 16);
      const body = 'hi from lumina 🔐';

      // Peer (lumina) fans out TO us (chef): our slot + a second device slot.
      final token = await codec.buildPqdm2(
        Uint8List.fromList(utf8.encode(body)),
        [
          Pqdm2Recipient(keyId: myKid, hybridPublicKey: me.publicKey),
          Pqdm2Recipient(keyId: otherKid, hybridPublicKey: other.publicKey),
        ],
        sender: 'lumina',
        recipientId: 'chef',
      );

      final svc = PqConversationService(
        prekeys: _RealKeyPrekeyService(keyIdValue: myKid, privValue: me.privateKey),
        localShort: 'chef',
        codec: codec,
      );
      final r = await svc.openIncomingDetailed('lumina', token);
      expect(r.opened, isTrue);
      expect(r.mine, isFalse);
      expect(r.text, body);
      expect(svc.isHybrid('lumina'), isTrue);
    });

    test('a fanout token with NO slot for this device -> locked placeholder',
        () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final codec = PqDmCodec();
      final me = await HybridKemImpl().generateKeyPair();
      final a = await HybridKemImpl().generateKeyPair();
      final b = await HybridKemImpl().generateKeyPair();
      final myKid = _bytesToHex(me.publicKey).substring(0, 16);
      final aKid = _bytesToHex(a.publicKey).substring(0, 16);
      final bKid = _bytesToHex(b.publicKey).substring(0, 16);

      final token = await codec.buildPqdm2(
        Uint8List.fromList(utf8.encode('not for this device')),
        [
          Pqdm2Recipient(keyId: aKid, hybridPublicKey: a.publicKey),
          Pqdm2Recipient(keyId: bKid, hybridPublicKey: b.publicKey),
        ],
        sender: 'lumina',
        recipientId: 'chef',
      );

      final svc = PqConversationService(
        prekeys: _RealKeyPrekeyService(keyIdValue: myKid, privValue: me.privateKey),
        localShort: 'chef',
        codec: codec,
      );
      final r = await svc.openIncomingDetailed('lumina', token);
      expect(r.opened, isFalse,
          reason: 'no slot for this device -> graceful locked, not a crash');
      expect(r.mine, isFalse);
      expect(r.text, PqConversationService.lockedCantOpenText);
    });

    test('a pqdm2 token with no device key -> lockedNoKeyText', () async {
      // No KEM needed: ensureKeyPair() == false short-circuits before any open.
      final svc = PqConversationService(
        prekeys: _RealKeyPrekeyService(
          keyIdValue: null,
          privValue: null,
          hasKey: false,
        ),
        localShort: 'chef',
        codec: PqDmCodec(),
      );
      final r = await svc.openIncomingDetailed(
          'lumina', 'pqdm2:eyJ2IjoyfQ==.AAAA.BBBB');
      expect(r.opened, isFalse);
      expect(r.mine, isFalse);
      expect(r.text, PqConversationService.lockedNoKeyText);
    });
  });
}
