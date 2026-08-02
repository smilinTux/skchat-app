import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sk_pqc/sk_pqc.dart';

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

/// A fixture armored OpenPGP signature block. Its bytes are not cryptographically
/// meaningful (server-side interop is proven by the Python
/// `test_prekey_armored_interop.py` against the real pgpy verifier); here we only
/// assert the app ATTACHES the armored block returned by the daemon.
const _armoredFixture = '''-----BEGIN PGP SIGNATURE-----

iHUEABYKAB0WIQTfixtureFixtureFixtureFixtureFixtureFAAKCRBfixtureAA
fixturefixturefixturefixturefixturefixturefixturefixturefixturefix
=Fx01
-----END PGP SIGNATURE-----''';

/// A [PrekeyArmorSigner] that records the fields it was asked to sign and
/// returns the fixture armored block (or null to simulate a failed signing).
class _FakeArmorSigner implements PrekeyArmorSigner {
  _FakeArmorSigner({this.result = _armoredFixture});

  final String? result;
  Map<String, String>? lastArgs;

  @override
  Future<String?> sign({
    required String hybridPublicHex,
    required String keyId,
    required String suite,
  }) async {
    lastArgs = {
      'hybrid_public_hex': hybridPublicHex,
      'key_id': keyId,
      'suite': suite,
    };
    return result;
  }
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

  group('armored prekey bundle signing (daemon operator-sign path)', () {
    // 1216-byte hybrid public key + 2432-byte private key, deterministic.
    final pub = Uint8List.fromList(List<int>.filled(1216, 0x07));
    final priv = Uint8List.fromList(List<int>.filled(2432, 0x09));

    test('myBundle() attaches the armored signature from the daemon signer',
        () async {
      final signer = _FakeArmorSigner();
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: _FixedHybridKem(pub, priv),
        armorSigner: signer,
      );

      expect(await svc.ensureKeyPair(), isTrue);
      final bundle = await svc.myBundle();

      // Advertises the pqdm2 fanout capability.
      expect(bundle.codec, 'pqdm2');
      expect(bundle.isHybrid, isTrue);

      // The signature is a real ASCII-armored OpenPGP detached signature block,
      // NOT raw RSA base64 (which the server pgpy verifier would reject).
      expect(bundle.signature, isNotNull);
      expect(
        bundle.signature!.contains('-----BEGIN PGP SIGNATURE-----'),
        isTrue,
      );
      expect(bundle.signature, _armoredFixture);

      // The daemon signer was asked to sign EXACTLY the bundle's identity fields
      // (which the daemon canonicalizes to the server's signed bytes).
      expect(signer.lastArgs, isNotNull);
      expect(signer.lastArgs!['hybrid_public_hex'], bundle.hybridPublicHex);
      expect(signer.lastArgs!['key_id'], bundle.keyId);
      expect(signer.lastArgs!['suite'], bundle.suite);

      // Sanity: those fields canonicalize to the exact server bytes.
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
    });

    test('toJson carries the armored signature under both signature and sig',
        () async {
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: _FixedHybridKem(pub, priv),
        armorSigner: _FakeArmorSigner(),
      );
      await svc.ensureKeyPair();
      final json = (await svc.myBundle()).toJson();
      expect(json['codec'], 'pqdm2');
      expect(json['signature'], _armoredFixture);
      expect(
        (json['signature'] as String).contains('-----BEGIN PGP SIGNATURE-----'),
        isTrue,
      );
      // Plan field alias: publish the same armored signature under `sig` too.
      expect(json['sig'], json['signature']);
    });

    test('signing failure (daemon unreachable) publishes unsigned', () async {
      final svc = PqPrekeyService(
        storage: const FlutterSecureStorage(),
        baseUrl: 'http://localhost:9384',
        deviceId: 'test-device',
        kem: _FixedHybridKem(pub, priv),
        armorSigner: _FakeArmorSigner(result: null),
      );
      await svc.ensureKeyPair();
      final bundle = await svc.myBundle();
      expect(bundle.signature, isNull);
    });
  });

  group('DaemonPrekeyArmorSigner', () {
    test('POSTs the canonical fields and returns the armored signature',
        () async {
      Map<String, dynamic>? sentBody;
      String? sentPath;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:9384'));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          sentPath = options.path;
          sentBody = Map<String, dynamic>.from(options.data as Map);
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: {'ok': true, 'signature': _armoredFixture},
          ));
        },
      ));

      final signer = DaemonPrekeyArmorSigner(dio);
      final sig = await signer.sign(
        hybridPublicHex: 'ab' * 16,
        keyId: 'abababababababab',
        suite: PqDmCodec.hybridSuite,
      );

      expect(sentPath, '/api/v1/prekey/sign');
      expect(sentBody!['hybrid_public_hex'], 'ab' * 16);
      expect(sentBody!['key_id'], 'abababababababab');
      expect(sentBody!['suite'], PqDmCodec.hybridSuite);
      expect(sig, _armoredFixture);
    });

    test('returns null when the daemon does not return an armored block',
        () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:9384'));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: {'ok': true, 'signature': 'not-an-armored-block'},
          ));
        },
      ));
      final signer = DaemonPrekeyArmorSigner(dio);
      final sig = await signer.sign(
        hybridPublicHex: 'ab' * 16,
        keyId: 'abababababababab',
        suite: PqDmCodec.hybridSuite,
      );
      expect(sig, isNull);
    });

    test('returns null on a transport error (unsigned fallback)', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:9384'));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(DioException(
            requestOptions: options,
            error: 'boom',
          ));
        },
      ));
      final signer = DaemonPrekeyArmorSigner(dio);
      final sig = await signer.sign(
        hybridPublicHex: 'ab' * 16,
        keyId: 'abababababababab',
        suite: PqDmCodec.hybridSuite,
      );
      expect(sig, isNull);
    });
  });
}
