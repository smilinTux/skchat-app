import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sk_pqc/sk_pqc.dart';

import 'daemon_config.dart';
import 'pq_dm_codec.dart';

/// A peer's published hybrid-KEM prekey (PQXDH-style). Mirrors
/// `skcomms.pqdm.PrekeyBundle`. A peer that advertises a hybrid prekey
/// (`isHybrid == true`) can receive hybrid-sealed DMs; one that doesn't gets the
/// classical path (negotiated downgrade).
class PrekeyBundle {
  const PrekeyBundle({
    this.suite = PqDmCodec.classicalSuite,
    this.hybridPublicHex = '',
    this.signature,
    this.keyId,
    this.deviceId,
  });

  final String suite;
  final String hybridPublicHex; // hex of the 1216-byte hybrid public key
  final String? signature; // classical signature (Phase 2, opaque here)
  final String? keyId;
  final String? deviceId;

  bool get isHybrid =>
      suite == PqDmCodec.hybridSuite && hybridPublicHex.isNotEmpty;

  Uint8List hybridPublic() => _hexToBytes(hybridPublicHex);

  Map<String, dynamic> toJson() => {
        'suite': suite,
        'hybrid_public_hex': hybridPublicHex,
        'signature': signature,
        'key_id': keyId,
        'device_id': deviceId,
      };

  factory PrekeyBundle.fromJson(Map<String, dynamic>? data) {
    if (data == null) return const PrekeyBundle();
    return PrekeyBundle(
      suite: data['suite'] as String? ?? PqDmCodec.classicalSuite,
      hybridPublicHex: (data['hybrid_public_hex'] as String?) ?? '',
      signature: data['signature'] as String?,
      keyId: data['key_id'] as String?,
      deviceId: data['device_id'] as String?,
    );
  }
}

/// Persists this device's hybrid keypair + publishes/fetches prekey bundles.
///
/// - Generates a per-device hybrid keypair once (sk_pqc), persists it in secure
///   storage (hex), and reuses it across sessions.
/// - Publishes a [PrekeyBundle] to the daemon (`POST /api/v1/prekey`) on startup.
/// - Fetches a peer's bundle (`GET /api/v1/prekey/{peer}`), cached in-process.
///
/// On web the keypair generation uses sk_pqc's noble backend (globalThis.skPqc);
/// if noble isn't bundled, generation throws and the app stays classical-only
/// (caller catches → no prekey published → negotiated downgrade everywhere).
class PqPrekeyService {
  PqPrekeyService({
    required FlutterSecureStorage storage,
    required String baseUrl,
    required String deviceId,
    HybridKem? kem,
    Dio? dio,
  })  : _storage = storage,
        _deviceId = deviceId,
        _kem = kem ?? HybridKemImpl(),
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              // Generous timeouts: the webui can be busy during the load burst,
              // and a 5s connect timeout was making the prekey fetch fail →
              // silently downgrading the conversation to classical.
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'Content-Type': 'application/json'},
            ));

  static const _kPub = 'pqc_hybrid_public_hex';
  static const _kPriv = 'pqc_hybrid_private_hex';
  static const _kKeyId = 'pqc_hybrid_key_id';
  static const _kDeviceId = 'pqc_device_id';

  final FlutterSecureStorage _storage;
  String _deviceId;
  final HybridKem _kem;
  final Dio _dio;

  HybridKeyPair? _keyPair;
  String? _keyId;
  bool _available = false;
  final Map<String, PrekeyBundle> _peerCache = {};

  /// Whether this device has a usable hybrid keypair (so it can do hybrid DMs).
  bool get hybridAvailable => _available;
  String? get keyId => _keyId;

  /// The 2432-byte hybrid private key (null until [ensureKeyPair]).
  Uint8List? get privateKey => _keyPair?.privateKey;

  /// Load-or-generate the per-device hybrid keypair. Idempotent; safe to call on
  /// startup. Returns true if a hybrid keypair is now available.
  Future<bool> ensureKeyPair() async {
    if (_available && _keyPair != null) return true;
    try {
      // Resolve a stable per-device id (persisted once).
      final storedDev = await _storage.read(key: _kDeviceId);
      if (storedDev != null && storedDev.isNotEmpty) {
        _deviceId = storedDev;
      } else {
        await _storage.write(key: _kDeviceId, value: _deviceId);
      }
      final pubHex = await _storage.read(key: _kPub);
      final privHex = await _storage.read(key: _kPriv);
      _keyId = await _storage.read(key: _kKeyId);
      if (pubHex != null && privHex != null && _keyId != null) {
        _keyPair = HybridKeyPair(
          publicKey: _hexToBytes(pubHex),
          privateKey: _hexToBytes(privHex),
        );
        _available = true;
        return true;
      }
      // First run on this device → generate + persist.
      final kp = await _kem.generateKeyPair();
      final id = _shortId(kp.publicKey);
      await _storage.write(key: _kPub, value: _bytesToHex(kp.publicKey));
      await _storage.write(key: _kPriv, value: _bytesToHex(kp.privateKey));
      await _storage.write(key: _kKeyId, value: id);
      _keyPair = kp;
      _keyId = id;
      _available = true;
      return true;
    } catch (_) {
      // No PQ backend (e.g. noble not bundled on web) → classical-only.
      _available = false;
      return false;
    }
  }

  /// This device's own [PrekeyBundle] (hybrid if available, else classical).
  PrekeyBundle myBundle() {
    if (_available && _keyPair != null) {
      return PrekeyBundle(
        suite: PqDmCodec.hybridSuite,
        hybridPublicHex: _bytesToHex(_keyPair!.publicKey),
        // Signature stays classical (Phase 2 / Q7); left null until the daemon
        // signs the prekey with the identity key.
        signature: null,
        keyId: _keyId,
        deviceId: _deviceId,
      );
    }
    return PrekeyBundle(deviceId: _deviceId);
  }

  /// Publish this device's prekey bundle to the daemon. Best-effort; returns
  /// true on a 2xx. No-op (returns false) when no hybrid keypair is available.
  Future<bool> publish() async {
    if (!_available) return false;
    try {
      final resp = await _dio.post('/api/v1/prekey', data: myBundle().toJson());
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  /// Fetch a peer's prekey bundle. Cached in-process; returns a classical
  /// (non-hybrid) bundle on any error so the caller takes the classical path.
  Future<PrekeyBundle> fetchPeer(String peer, {bool force = false}) async {
    final key = _peerShort(peer);
    if (!force && _peerCache.containsKey(key)) return _peerCache[key]!;
    try {
      final resp = await _dio.get<dynamic>(
        '/api/v1/prekey/${Uri.encodeComponent(key)}',
      );
      final data = resp.data;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      // Tolerate `{prekey:{...}}` or a bare bundle.
      final bundleMap = map != null && map['prekey'] is Map
          ? Map<String, dynamic>.from(map['prekey'] as Map)
          : map;
      final bundle = PrekeyBundle.fromJson(bundleMap);
      _peerCache[key] = bundle;
      return bundle;
    } catch (e) {
      // Do NOT cache a failed fetch, a transient timeout must not permanently
      // pin the conversation to classical. The next send retries the fetch.
      return const PrekeyBundle();
    }
  }

  void invalidatePeer(String peer) => _peerCache.remove(_peerShort(peer));

  static String _peerShort(String uri) {
    var s = uri.startsWith('capauth:') ? uri.substring('capauth:'.length) : uri;
    return s.split('@').first;
  }

  static String _shortId(Uint8List pub) {
    // 8-hex prefix of the public key, stable per device, opaque (rotation id).
    final h = _bytesToHex(pub);
    return h.substring(0, h.length < 16 ? h.length : 16);
  }
}

// ── hex helpers (shared) ─────────────────────────────────────────────────────

String _bytesToHex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw const SkPqcError('hex string must have an even length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

// ── Riverpod wiring ──────────────────────────────────────────────────────────

final _pqSecureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  ),
);

final pqPrekeyServiceProvider = Provider<PqPrekeyService>((ref) {
  final baseUrl = ref.watch(daemonUrlProvider);
  // A coarse seed device id; the service persists+reuses it (and the key-id is
  // the real rotation selector). One service per daemon-url binding.
  final seed = 'dev-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  return PqPrekeyService(
    storage: ref.watch(_pqSecureStorageProvider),
    baseUrl: baseUrl,
    deviceId: seed,
  );
});

/// Startup bootstrap: ensure the per-device hybrid keypair exists and publish
/// this device's prekey bundle so peers (and Lumina) can seal to it. Best-effort
///, returns false if no PQ backend is available (web without noble bundled),
/// in which case the app stays classical-only (negotiated downgrade). Watched
/// eagerly in `main` so the prekey is published before the first send.
final pqBootstrapProvider = FutureProvider<bool>((ref) async {
  final svc = ref.watch(pqPrekeyServiceProvider);
  final ok = await svc.ensureKeyPair();
  if (ok) {
    await svc.publish();
  }
  return ok;
});
