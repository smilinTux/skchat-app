import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sk_pqc/sk_pqc.dart';
import 'package:skchat/services/pq_backend.dart';
import 'package:skchat/services/pq_conversation_service.dart';
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';

/// A prekey fake that reports whether this device has a usable keypair. When
/// [hasKey] is false it models a device whose PQ backend could not load
/// (liboqs missing) — exactly what [UnavailableHybridKem] produces via the real
/// [PqPrekeyService.ensureKeyPair] catch.
class _FakePrekeyService implements PqPrekeyService {
  _FakePrekeyService({required this.hasKey});
  bool hasKey;

  @override
  Future<bool> ensureKeyPair() async => hasKey;

  @override
  Uint8List? get privateKey => null;

  @override
  Future<PrekeyBundle> fetchPeer(String peer, {bool force = false}) async {
    // Peer advertises hybrid; the point of the test is that OUR side has no key.
    return PrekeyBundle(
      suite: PqDmCodec.hybridSuite,
      hybridPublicHex: '00' * 1216,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UnavailableHybridKem', () {
    final kem = UnavailableHybridKem();

    test('info is the standard combiner label (safe to read)', () {
      expect(kem.info, HybridCombiner.defaultInfo);
    });

    test('generateKeyPair throws SkPqcError (never a raw crash)', () {
      expect(kem.generateKeyPair(), throwsA(isA<SkPqcError>()));
    });

    test('encapsulate throws SkPqcError', () {
      expect(
          kem.encapsulate(Uint8List(1216)), throwsA(isA<SkPqcError>()));
    });

    test('decapsulate throws SkPqcError', () {
      expect(kem.decapsulate(Uint8List(1120), Uint8List(2432)),
          throwsA(isA<SkPqcError>()));
    });
  });

  test('createHybridKemOrUnavailable never throws at construction', () {
    // The whole point of the fix: constructing the backend must be total even
    // when liboqs cannot load. In this test env liboqs may or may not be
    // present; either way construction must return a HybridKem, never throw.
    late HybridKem kem;
    expect(() => kem = createHybridKemOrUnavailable(), returnsNormally);
    expect(kem, isA<HybridKem>());
  });

  group('PqPrekeyService with an unavailable backend degrades to classical', () {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

    setUp(() {
      // Empty secure storage → a "fresh device" so ensureKeyPair() proceeds to
      // generateKeyPair(), which the unavailable backend makes throw.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'read':
            return null;
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return false;
          default:
            return null; // write/delete/deleteAll are no-ops
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('ensureKeyPair() returns false and stays classical-only', () async {
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: UnavailableHybridKem(),
      );
      expect(await svc.ensureKeyPair(), isFalse);
      expect(svc.hybridAvailable, isFalse);
      expect((await svc.myBundle()).isHybrid, isFalse);
      expect(await svc.publish(), isFalse);
    });
  });

  group('PqConversationService without a device key seals classically', () {
    test('sealOutgoing returns the body unchanged (no crash, classical)',
        () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hasKey: false),
        localShort: 'chef',
      );
      final wire = await svc.sealOutgoing('lumina', 'hello');
      expect(wire, 'hello');
      expect(svc.stateFor('lumina'), PqConversationState.classical);
    });

    test('openIncoming on a foreign pqdm token yields a placeholder, not a throw',
        () async {
      final svc = PqConversationService(
        prekeys: _FakePrekeyService(hasKey: false),
        localShort: 'chef',
      );
      final shown =
          await svc.openIncoming('lumina', 'pqdm1:x25519-mlkem768:AAAA');
      expect(shown, contains('post-quantum message'));
    });
  });
}
