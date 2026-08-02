import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// Task 11: the app sender fans out on send.
///
/// `sealOutgoing` seals ONE `pqdm2:` envelope wrapped per recipient device slot
/// (every peer device AND every sender-own device), so:
///   1. the peer's devices open it, and
///   2. the sender's OWN devices open it (own-outbound rendering with NO Hive
///      plaintext cache / no `recordOutbound`).
///
/// Requires the native liboqs backend. Skips cleanly where it is unavailable.
class _Device {
  _Device(this.keyId, this.pub, this.priv);
  final String keyId;
  final Uint8List pub;
  final Uint8List priv;
}

Future<_Device> _gen(HybridKem kem) async {
  final kp = await kem.generateKeyPair();
  return _Device(_deviceKeyId(kp.publicKey), kp.publicKey, kp.privateKey);
}

/// Same rotation-id rule the real service uses: 16-hex prefix of the pubkey.
String _deviceKeyId(Uint8List pub) {
  final h = _hex(pub);
  return h.substring(0, h.length < 16 ? h.length : 16);
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

PrekeyBundle _slot(_Device d) => PrekeyBundle(
      suite: PqDmCodec.hybridSuite,
      hybridPublicHex: _hex(d.pub),
      keyId: d.keyId,
      codec: PrekeyBundle.pqdm2Codec,
    );

/// A [PqPrekeyService] backed by real KEM keypairs. `fetchPeer('chef')` returns
/// the sender's own device slots; `fetchPeer('lumina')` the peer's.
class _FanoutFakePrekey implements PqPrekeyService {
  _FanoutFakePrekey({
    required this.ownThis,
    required this.ownSlots,
    required this.peerSlots,
  });

  final _Device ownThis;
  final List<PrekeyBundle> ownSlots;
  final List<PrekeyBundle> peerSlots;

  @override
  Future<bool> ensureKeyPair() async => true;

  @override
  String? get keyId => ownThis.keyId;

  @override
  Uint8List? get privateKey => ownThis.priv;

  @override
  Future<PrekeyBundle> myBundle() async => _slot(ownThis);

  @override
  Future<List<PrekeyBundle>> fetchPeer(String peer, {bool force = false}) async =>
      peer == 'chef' ? ownSlots : peerSlots;

  @override
  Future<PrekeyBundle> fetchPeerNewest(String peer, {bool force = false}) async {
    final l = await fetchPeer(peer, force: force);
    return l.isNotEmpty ? l.first : const PrekeyBundle();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _decodeHeader(String token) {
  final rest = token.substring(PqDmCodec.pqdm2Prefix.length);
  final parts = rest.split('.');
  return jsonDecode(utf8.decode(base64.decode(parts[0]))) as Map<String, dynamic>;
}

void main() {
  bool kemAvailable() {
    try {
      HybridKemImpl();
      return true;
    } catch (_) {
      return false;
    }
  }

  group('sealOutgoing fanout (needs liboqs)', () {
    test('token fans out to every peer AND sender-own device slot', () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final kem = HybridKemImpl();
      final chefThis = await _gen(kem); // this device
      final chefOther = await _gen(kem); // another of the sender's devices
      final lumina1 = await _gen(kem);
      final lumina2 = await _gen(kem);

      final fake = _FanoutFakePrekey(
        ownThis: chefThis,
        ownSlots: [_slot(chefThis), _slot(chefOther)],
        peerSlots: [_slot(lumina1), _slot(lumina2)],
      );
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');

      final token = await svc.sealOutgoing('lumina', 'hello from chef');
      expect(token.startsWith(PqDmCodec.pqdm2Prefix), isTrue,
          reason: 'a pqdm2-advertised peer must seal a pqdm2: fanout envelope');

      final kids = (_decodeHeader(token)['kids'] as List).cast<String>();
      // The sender's OWN device key_id is in the header (proves own-device
      // rendering without recordOutbound).
      expect(kids, contains(chefThis.keyId));
      expect(kids, contains(chefOther.keyId));
      expect(kids, contains(lumina1.keyId));
      expect(kids, contains(lumina2.keyId));

      final codec = PqDmCodec();
      // Own device opens its slot -> plaintext (no Hive recall needed).
      final own = await codec.openPqdm2(token,
          myKeyId: chefThis.keyId,
          myPrivate: chefThis.priv,
          sender: 'chef',
          recipientId: 'lumina');
      expect(own, isNotNull);
      expect(utf8.decode(own!), 'hello from chef');

      // A peer device opens its own slot -> the same plaintext.
      final peer = await codec.openPqdm2(token,
          myKeyId: lumina1.keyId,
          myPrivate: lumina1.priv,
          sender: 'chef',
          recipientId: 'lumina');
      expect(utf8.decode(peer!), 'hello from chef');

      // Another sender-own device opens its slot too.
      final other = await codec.openPqdm2(token,
          myKeyId: chefOther.keyId,
          myPrivate: chefOther.priv,
          sender: 'chef',
          recipientId: 'lumina');
      expect(utf8.decode(other!), 'hello from chef');
    });

    test('own outbound renders via openIncomingDetailed with NO recordOutbound',
        () async {
      if (!kemAvailable()) {
        markTestSkipped('liboqs native backend unavailable');
        return;
      }
      final kem = HybridKemImpl();
      final chefThis = await _gen(kem);
      final lumina1 = await _gen(kem);

      final fake = _FanoutFakePrekey(
        ownThis: chefThis,
        ownSlots: [_slot(chefThis)],
        peerSlots: [_slot(lumina1)],
      );
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');

      final token = await svc.sealOutgoing('lumina', 'my own text');
      // NO recordOutbound was called; the echo of our own token from history is
      // opened straight from this device's own slot.
      final r = await svc.openIncomingDetailed('lumina', token);
      expect(r.opened, isTrue);
      expect(r.mine, isTrue, reason: 'header sender == local short -> our own');
      expect(r.text, 'my own text');
      expect(svc.isHybrid('lumina'), isTrue);
    });
  });
}
