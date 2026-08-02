import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sk_pqc/sk_pqc.dart';

import 'package:skchat/core/crypto/pgp_bridge.dart';
import 'package:skchat/services/join_service.dart' show SovereignSigner;
import 'package:skchat/services/pq_dm_codec.dart';
import 'package:skchat/services/pq_prekey_service.dart';

/// A hybrid KEM that yields a deterministic keypair so the published bundle's
/// `hybrid_public_hex` / `key_id` are stable and the canonical signed bytes are
/// predictable. Only [generateKeyPair] is exercised by [PqPrekeyService.myBundle].
class _FixedHybridKem extends HybridKem {
  _FixedHybridKem(this._pub, this._priv);

  final Uint8List _pub;
  final Uint8List _priv;

  @override
  String get info => HybridCombiner.defaultInfo;

  @override
  Future<HybridKeyPair> generateKeyPair() async =>
      HybridKeyPair(publicKey: _pub, privateKey: _priv);

  @override
  Future<EncapResult> encapsulate(Uint8List peerPublicKey) async =>
      throw const SkPqcError('not used in this test');

  @override
  Future<Uint8List> decapsulate(Uint8List ciphertext, Uint8List privateKey) async =>
      throw const SkPqcError('not used in this test');
}

/// A [SovereignSigner] backed by the app's real PGP identity primitive
/// ([PgpBridge]) so the test can both sign the canonical bundle payload and
/// verify the resulting signature against the device public key, using the SAME
/// canonicalization the server ([skchat.prekey_sig.verify_prekey_bundle]) uses.
class _PgpBundleSigner implements SovereignSigner {
  _PgpBundleSigner(this._keyPair);
  final PgpKeyPair _keyPair;

  @override
  Future<String> sign(String claim) =>
      PgpBridge.signAsync(claim, _keyPair.privateKeyPem);
}

/// The server's canonical signed bytes:
///   json.dumps({hybrid_public_hex, key_id, suite}, sort_keys=True,
///              separators=(",",":")).encode("utf-8")
/// Keys sorted alphabetically, compact separators (no spaces).
String _expectedServerCanonical({
  required String hybridPublicHex,
  required String keyId,
  required String suite,
}) =>
    jsonEncode(<String, dynamic>{
      'hybrid_public_hex': hybridPublicHex,
      'key_id': keyId,
      'suite': suite,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    // Fresh device: empty secure storage so ensureKeyPair() generates via the
    // injected fixed KEM.
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
          return null; // write/delete are no-ops
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('signed prekey bundle (Task 5)', () {
    // 1216-byte hybrid public key + 2432-byte private key, deterministic.
    final pub = Uint8List.fromList(List<int>.filled(1216, 0x07));
    final priv = Uint8List.fromList(List<int>.filled(2432, 0x09));

    late PgpKeyPair deviceKey;

    setUpAll(() async {
      // Small RSA key: fast to generate, still valid for PKCS#1 SHA-256.
      deviceKey = await PgpBridge.generateKeyPair(bits: 1024);
    });

    test('myBundle() advertises codec pqdm2 and signs the canonical payload',
        () async {
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: _FixedHybridKem(pub, priv),
        bundleSigner: _PgpBundleSigner(deviceKey),
      );

      expect(await svc.ensureKeyPair(), isTrue);

      final bundle = await svc.myBundle();

      // Advertises the pqdm2 fanout capability.
      expect(bundle.codec, 'pqdm2');
      expect(bundle.isHybrid, isTrue);

      // Signature is present and non-empty.
      expect(bundle.signature, isNotNull);
      expect(bundle.signature!.isNotEmpty, isTrue);

      // The signed bytes are EXACTLY the server's canonical bytes.
      final expectedCanonical = _expectedServerCanonical(
        hybridPublicHex: bundle.hybridPublicHex,
        keyId: bundle.keyId!,
        suite: bundle.suite,
      );
      expect(
        expectedCanonical,
        '{"hybrid_public_hex":"${'07' * 1216}",'
        '"key_id":"${'07' * 8}","suite":"${PqDmCodec.hybridSuite}"}',
      );

      // The signature verifies against the device public key with the SAME
      // canonicalization the server uses.
      final ok = await PgpBridge.verifyAsync(
        expectedCanonical,
        bundle.signature!,
        deviceKey.publicKeyPem,
      );
      expect(ok, isTrue);
    });

    test('toJson carries the signature under both signature and sig', () async {
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: _FixedHybridKem(pub, priv),
        bundleSigner: _PgpBundleSigner(deviceKey),
      );
      await svc.ensureKeyPair();
      final json = (await svc.myBundle()).toJson();
      expect(json['codec'], 'pqdm2');
      expect(json['signature'], isNotNull);
      expect((json['signature'] as String).isNotEmpty, isTrue);
      // Plan field alias: publish the same armored signature under `sig` too.
      expect(json['sig'], json['signature']);
    });

    test('without a signer the bundle is unsigned (pqdm1 back-compat)',
        () async {
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: _FixedHybridKem(pub, priv),
      );
      await svc.ensureKeyPair();
      final bundle = await svc.myBundle();
      expect(bundle.signature, isNull);
    });
  });
}
