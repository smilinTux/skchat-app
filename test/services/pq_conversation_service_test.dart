import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';

/// Unit tests for the BUG-1 own-outbound rendering + BUG-2 no-downgrade logic.
///
/// These do NOT need liboqs: the own-outbound recall path short-circuits before
/// any KEM op, and the no-downgrade-on-fetch-failure path only exercises state
/// bookkeeping. A fake [PqPrekeyService] feeds a hybrid / classical bundle.
class _FakePrekeyService implements PqPrekeyService {
  _FakePrekeyService({required this.hybrid});

  bool hybrid;
  bool hasKey = true;
  int fetchCalls = 0;

  @override
  Future<bool> ensureKeyPair() async => hasKey;

  @override
  Future<PrekeyBundle> fetchPeer(String peer, {bool force = false}) async {
    fetchCalls++;
    if (!hybrid) return const PrekeyBundle();
    // A syntactically-valid hybrid bundle (1216-byte all-zero public key). We
    // never actually seal in these tests (the fake codec does), so the bytes
    // only need to satisfy isHybrid + the length check at use sites we hit.
    return PrekeyBundle(
      suite: PqDmCodec.hybridSuite,
      hybridPublicHex: '00' * 1216,
    );
  }

  // Unused in these tests.
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The own-outbound map is backed by a Hive box; init Hive on a temp dir so
  // recordOutbound/recallOutbound exercise the real persistence path (and the
  // openBox call doesn't raise an unhandled async HiveError).
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('skchat_pq_convo_test');
    Hive.init(tmp.path);
  });
  tearDown(() async {
    await Hive.close();
    await Hive.deleteFromDisk();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('own-outbound recall (BUG 1)', () {
    test('recordOutbound → recallOutbound returns the plaintext', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      const token = 'pqdm1:x25519-mlkem768:AAAA';
      const plain = 'hello lumina';
      await svc.recordOutbound(token, plain);
      expect(await svc.recallOutbound(token), plain);
      expect(svc.recallOutboundSync(token), plain);
    });

    test('openIncoming on our OWN token returns plaintext, flips hybrid',
        () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      const token = 'pqdm1:x25519-mlkem768:BBBB';
      const plain = 'my own outbound 🔐';
      await svc.recordOutbound(token, plain);
      // openIncoming must return the remembered plaintext WITHOUT attempting to
      // decapsulate (it was sealed to the peer, not us) — never ciphertext.
      final shown = await svc.openIncoming('lumina', token);
      expect(shown, plain);
      expect(svc.isHybrid('lumina'), isTrue);
    });

    test('a non-own token is NOT recalled (miss → null)', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      expect(await svc.recallOutbound('pqdm1:x25519-mlkem768:NOTOURS'), isNull);
    });

    test('non-token body passes through openIncoming unchanged', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      expect(await svc.openIncoming('lumina', 'plain text'), 'plain text');
    });
  });

  group('no silent downgrade (BUG 2)', () {
    test('prefetchPeer records hybrid for a hybrid peer', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      await svc.prefetchPeer('lumina');
      expect(svc.isHybrid('lumina'), isTrue);
      expect(svc.stateFor('lumina'), PqConversationState.hybridPq);
    });

    test('a known-hybrid convo is NOT downgraded when a later fetch is classical',
        () async {
      final fake = _FakePrekeyService(hybrid: true);
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');
      // Negotiate hybrid first.
      await svc.prefetchPeer('lumina');
      expect(svc.isHybrid('lumina'), isTrue);
      // Now a later fetch comes back classical (busy webui / transient) — the
      // conversation must STAY hybrid, not flip the badge to classical.
      fake.hybrid = false;
      await svc.sealOutgoing('lumina', 'still hybrid?');
      expect(svc.isHybrid('lumina'), isTrue,
          reason: 'a transient classical fetch must not downgrade a hybrid convo');
    });

    test('a never-hybrid convo is classical (honest)', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: false),
        localShort: 'chef',
      );
      final wire = await svc.sealOutgoing('bob', 'hi');
      expect(wire, 'hi'); // unchanged, classical
      expect(svc.stateFor('bob'), PqConversationState.classical);
    });

    test('control sentinels are never sealed', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      const sentinel = '__TYPING__:{"state":"start"}';
      expect(await svc.sealOutgoing('lumina', sentinel), sentinel);
    });
  });
}
