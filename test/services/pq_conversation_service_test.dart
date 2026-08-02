import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';

/// Unit tests for the no-downgrade (BUG 2) logic and the CARD E locked
/// placeholder. Own-outbound rendering moved to the `pqdm2:` fanout path (a
/// device is its own recipient slot), proven in `seal_outgoing_fanout_test.dart`;
/// the retired Hive `recordOutbound`/`recallOutbound` recall path is gone.
///
/// These do NOT need liboqs: the classical / no-downgrade paths only exercise
/// state bookkeeping. A fake [PqPrekeyService] feeds a hybrid / classical bundle.
class _FakePrekeyService implements PqPrekeyService {
  _FakePrekeyService({required this.hybrid});

  bool hybrid;
  bool hasKey = true;
  int fetchCalls = 0;

  PrekeyBundle _bundle() {
    if (!hybrid) return const PrekeyBundle();
    // A syntactically-valid hybrid bundle (1216-byte all-zero public key). We
    // never actually seal in these tests, so the bytes only need to satisfy
    // isHybrid + the length check at use sites we hit. No `codec: pqdm2` advert,
    // so sealOutgoing stays on the (non-sealing) pqdm1 fallback branch here.
    return PrekeyBundle(
      suite: PqDmCodec.hybridSuite,
      hybridPublicHex: '00' * 1216,
    );
  }

  @override
  Future<bool> ensureKeyPair() async => hasKey;

  @override
  Future<List<PrekeyBundle>> fetchPeer(String peer, {bool force = false}) async {
    fetchCalls++;
    final b = _bundle();
    return b.isHybrid ? [b] : const [];
  }

  @override
  Future<PrekeyBundle> fetchPeerNewest(String peer, {bool force = false}) async {
    fetchCalls++;
    return _bundle();
  }

  // Unused in these tests.
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('openIncoming passthrough', () {
    test('non-token body passes through openIncoming unchanged', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      expect(await svc.openIncoming('lumina', 'plain text'), 'plain text');
    });
  });

  // CARD E: a sealed reply this device can't open reports opened=false
  group('openIncomingDetailed (CARD E, web/PWA locked placeholder)', () {
    test('non-token body → opened=true, passthrough', () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hybrid: true),
        localShort: 'chef',
      );
      final r = await svc.openIncomingDetailed('lumina', 'plain hello');
      expect(r.opened, isTrue);
      expect(r.mine, isFalse);
      expect(r.text, 'plain hello');
    });

    test('sealed peer token with NO key → opened=false, locked placeholder',
        () async {
      final fake = _FakePrekeyService(hybrid: true)..hasKey = false;
      final svc = PqConversationService(prekeys: fake, localShort: 'chef');
      final r = await svc
          .openIncomingDetailed('lumina', 'pqdm1:x25519-mlkem768:NOTOURS');
      expect(r.opened, isFalse, reason: 'no key on this device → cannot open');
      expect(r.mine, isFalse);
      expect(r.text, PqConversationService.lockedNoKeyText);
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
