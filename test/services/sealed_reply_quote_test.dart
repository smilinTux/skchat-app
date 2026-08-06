import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';
import 'package:sk_pqc/sk_pqc.dart';

/// Cross-device reply-quote over a SEALED DM (card 5a19f848, sealed leg).
///
/// A reply that carries a quote AND seals cannot ship the quote as a plaintext
/// top-level field (an anti-leak guard nulls those on sealed sends). Instead the
/// quote is wrapped INSIDE the sealed plaintext with a `skq1:` prefix, so the
/// recipient/sibling recovers it only after decrypting. These tests prove:
///
///  1. `sealOutgoing` with a quote round-trips through `openIncomingDetailed`
///     to the real body AND the quoted fields, and
///  2. the sealed wire token contains NO plaintext copy of the quote (it is
///     inside the ciphertext), and
///  3. a non-quote sealed send opens with null quoted fields (back-compat).
///
/// Requires the native liboqs backend; skips cleanly where unavailable.
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

void main() {
  bool kemAvailable() {
    try {
      HybridKemImpl();
      return true;
    } catch (_) {
      return false;
    }
  }

  group('sealed reply-quote skq1 envelope (needs liboqs)', () {
    test('sealed reply round-trips body AND quote through openIncomingDetailed',
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

      const body = 'yes that works';
      const quote = 'can you meet at 3?';
      final token = await svc.sealOutgoing(
        'lumina',
        body,
        quotedText: quote,
        quotedSender: 'Lumina',
        quotedId: 'orig-42',
      );
      expect(token.startsWith(PqDmCodec.pqdm2Prefix), isTrue);

      // Our own echo opens from our own slot: body is the REAL body (not the
      // skq1: wrapper), and the quote fields are recovered.
      final r = await svc.openIncomingDetailed('lumina', token);
      expect(r.opened, isTrue);
      expect(r.mine, isTrue);
      expect(r.text, body);
      expect(r.quotedText, quote);
      expect(r.quotedSender, 'Lumina');
      expect(r.quotedId, 'orig-42');
    });

    test('the sealed wire token leaks NO plaintext copy of the quote', () async {
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

      const secretQuote = 'TOP-SECRET-QUOTE-STRING';
      final token = await svc.sealOutgoing(
        'lumina',
        'the body',
        quotedText: secretQuote,
        quotedSender: 'Lumina',
        quotedId: 'orig-1',
      );
      // The quote lives inside the ciphertext; it must not appear anywhere in
      // the wire token (neither the header nor any base64 chunk decodes to it).
      expect(token.contains(secretQuote), isFalse);
      expect(token.contains('skq1:'), isFalse);
      expect(token.contains('the body'), isFalse);
    });

    test('a non-quote sealed send opens with null quoted fields', () async {
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

      final token = await svc.sealOutgoing('lumina', 'plain no quote');
      final r = await svc.openIncomingDetailed('lumina', token);
      expect(r.opened, isTrue);
      expect(r.text, 'plain no quote');
      expect(r.quotedText, isNull);
      expect(r.quotedSender, isNull);
      expect(r.quotedId, isNull);
    });

    test('a plaintext passthrough reports null quoted fields', () async {
      // No KEM needed: a non-token body returns unchanged with null quotes.
      final kem = kemAvailable() ? HybridKemImpl() : null;
      if (kem == null) {
        // Build a service whose prekey backend reports no key so the body just
        // passes through.
        final fake = _FanoutFakePrekey(
          ownThis: _Device('kid', Uint8List(0), Uint8List(0)),
          ownSlots: const [],
          peerSlots: const [],
        );
        final svc = PqConversationService(prekeys: fake, localShort: 'chef');
        final r = await svc.openIncomingDetailed('lumina', 'plain hello');
        expect(r.text, 'plain hello');
        expect(r.quotedText, isNull);
        return;
      }
      final chefThis = await _gen(kem);
      final fake = _FanoutFakePrekey(
        ownThis: chefThis,
        ownSlots: [_slot(chefThis)],
        peerSlots: [_slot(chefThis)],
      );
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');
      final r = await svc.openIncomingDetailed('lumina', 'plain hello');
      expect(r.opened, isTrue);
      expect(r.text, 'plain hello');
      expect(r.quotedText, isNull);
      expect(r.quotedSender, isNull);
      expect(r.quotedId, isNull);
    });
  });
}
