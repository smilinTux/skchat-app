import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sk_pqc/sk_pqc.dart';

import 'daemon_config.dart';
import 'join_service.dart' show SovereignSigner;
import 'pgp_capauth_signer.dart' show sovereignSignerProvider;
import 'pq_backend.dart';
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
    this.codec,
  });

  /// Capability advert for the multi-device fanout envelope. A bundle carrying
  /// `codec == pqdm2Codec` tells senders this device can receive a `pqdm2:`
  /// multi-recipient token; older `pqdm1`-only builds omit it.
  static const String pqdm2Codec = 'pqdm2';

  final String suite;
  final String hybridPublicHex; // hex of the 1216-byte hybrid public key
  /// Detached, ASCII-armored PGP signature over the canonical identity-binding
  /// fields (`{hybrid_public_hex, key_id, suite}`), made with the enrolled
  /// device key. Verified server-side by `skchat.prekey_sig.verify_prekey_bundle`.
  /// Null on classical / unsigned (ANONYMOUS-mode) bundles.
  final String? signature;
  final String? keyId;
  final String? deviceId;

  /// Fanout capability advert (`pqdm2Codec`), or null for a `pqdm1`-only bundle.
  final String? codec;

  bool get isHybrid =>
      suite == PqDmCodec.hybridSuite && hybridPublicHex.isNotEmpty;

  Uint8List hybridPublic() => _hexToBytes(hybridPublicHex);

  Map<String, dynamic> toJson() => {
        'suite': suite,
        'hybrid_public_hex': hybridPublicHex,
        'signature': signature,
        // The plan / app publish contract also advertises the same armored
        // signature under `sig`; the server verifier reads `signature`, so we
        // send both to stay robust to either field name.
        'sig': signature,
        'key_id': keyId,
        'device_id': deviceId,
        'codec': codec,
      };

  factory PrekeyBundle.fromJson(Map<String, dynamic>? data) {
    if (data == null) return const PrekeyBundle();
    return PrekeyBundle(
      suite: data['suite'] as String? ?? PqDmCodec.classicalSuite,
      hybridPublicHex: (data['hybrid_public_hex'] as String?) ?? '',
      signature:
          (data['signature'] as String?) ?? (data['sig'] as String?),
      keyId: data['key_id'] as String?,
      deviceId: data['device_id'] as String?,
      codec: data['codec'] as String?,
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
    SovereignSigner? bundleSigner,
  })  : _storage = storage,
        _deviceId = deviceId,
        _kem = kem ?? HybridKemImpl(),
        _bundleSigner = bundleSigner,
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

  /// Signs the canonical prekey payload with the enrolled device / operator
  /// identity key. Null when no identity key is provisioned yet, in which case
  /// the bundle is published unsigned (ANONYMOUS mode / `pqdm1` back-compat).
  SovereignSigner? _bundleSigner;

  /// Wire (or replace) the enrolled-device signer after construction. Used by
  /// the bootstrap provider once the async identity keypair has resolved.
  set bundleSigner(SovereignSigner? signer) => _bundleSigner = signer;

  HybridKeyPair? _keyPair;
  String? _keyId;
  bool _available = false;
  final Map<String, List<PrekeyBundle>> _peerCache = {};

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

  /// The canonical UTF-8 bytes the identity signature covers, byte-for-byte
  /// identical to the server's
  /// `json.dumps({hybrid_public_hex, key_id, suite}, sort_keys=True,
  ///             separators=(",",":"))` (see `skchat.prekey_sig`). Dart's
  /// [jsonEncode] emits the same compact separators (no spaces) and we insert
  /// the keys in sorted (alphabetical) order to match `sort_keys=True`.
  static String canonicalSignedPayload({
    required String hybridPublicHex,
    required String keyId,
    required String suite,
  }) =>
      jsonEncode(<String, dynamic>{
        'hybrid_public_hex': hybridPublicHex,
        'key_id': keyId,
        'suite': suite,
      });

  /// This device's own [PrekeyBundle] (hybrid if available, else classical).
  ///
  /// When a hybrid keypair AND an enrolled-device signer are present, the
  /// bundle is SIGNED: it carries a detached PGP signature over
  /// [canonicalSignedPayload] and advertises `codec: pqdm2` so senders fan out
  /// to it. Without a signer it stays unsigned (ANONYMOUS / `pqdm1` back-compat).
  Future<PrekeyBundle> myBundle() async {
    if (_available && _keyPair != null) {
      final hybridPublicHex = _bytesToHex(_keyPair!.publicKey);
      final keyId = _keyId;
      String? sig;
      if (_bundleSigner != null && keyId != null) {
        try {
          sig = await _bundleSigner!.sign(canonicalSignedPayload(
            hybridPublicHex: hybridPublicHex,
            keyId: keyId,
            suite: PqDmCodec.hybridSuite,
          ));
        } catch (_) {
          // Signing failed (no key unlocked / isolate error). Publish
          // unsigned rather than blocking the prekey advert. The daemon accepts
          // unsigned bundles until SKCHAT_REQUIRE_SIGNED_PREKEYS is flipped on.
          sig = null;
        }
      }
      return PrekeyBundle(
        suite: PqDmCodec.hybridSuite,
        hybridPublicHex: hybridPublicHex,
        signature: sig,
        keyId: keyId,
        deviceId: _deviceId,
        // Advertise the multi-device fanout capability so senders emit pqdm2.
        codec: PrekeyBundle.pqdm2Codec,
      );
    }
    return PrekeyBundle(deviceId: _deviceId);
  }

  /// Publish this device's prekey bundle to the daemon. Best-effort; returns
  /// true on a 2xx. No-op (returns false) when no hybrid keypair is available.
  Future<bool> publish() async {
    if (!_available) return false;
    try {
      final bundle = await myBundle();
      final resp = await _dio.post('/api/v1/prekey', data: bundle.toJson());
      final code = resp.statusCode ?? 0;
      return code >= 200 && code < 300;
    } catch (_) {
      return false;
    }
  }

  /// Fetch ALL of a peer's published device slots (multi-device DM fanout,
  /// Phase 1). Returns the slot LIST newest-first so the sender can seal to
  /// every device. Cached in-process; returns an EMPTY list on any error so a
  /// transient timeout never permanently pins the conversation to classical
  /// (the next send retries the fetch).
  ///
  /// Back-compat: a daemon that predates the multi-slot response returns either
  /// `{prekey: {...}}` (single newest slot) or a bare bundle; both are folded
  /// into a one-element list here.
  Future<List<PrekeyBundle>> fetchPeer(String peer, {bool force = false}) async {
    final key = _peerShort(peer);
    if (!force && _peerCache.containsKey(key)) return _peerCache[key]!;
    try {
      final resp = await _dio.get<dynamic>(
        '/api/v1/prekey/${Uri.encodeComponent(key)}',
      );
      final data = resp.data;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final bundles = _parseBundles(map, data);
      _peerCache[key] = bundles;
      return bundles;
    } catch (e) {
      // Do NOT cache a failed fetch, a transient timeout must not permanently
      // pin the conversation to classical. The next send retries the fetch.
      return const [];
    }
  }

  /// Fetch the peer's NEWEST device slot as a single bundle (the pqdm1 fallback
  /// path). Returns a classical (non-hybrid) bundle when the peer has published
  /// nothing or on any error, so the caller takes the classical path.
  Future<PrekeyBundle> fetchPeerNewest(String peer, {bool force = false}) async {
    final bundles = await fetchPeer(peer, force: force);
    return bundles.isNotEmpty ? bundles.first : const PrekeyBundle();
  }

  /// Normalize the GET /prekey response into a slot list. Prefers the new
  /// `prekeys: [...]` list; otherwise tolerates the old `{prekey: {...}}` and
  /// bare-bundle shapes as a single-element list.
  static List<PrekeyBundle> _parseBundles(
      Map<String, dynamic>? map, dynamic raw) {
    if (map != null && map['prekeys'] is List) {
      return [
        for (final e in (map['prekeys'] as List))
          if (e is Map)
            PrekeyBundle.fromJson(Map<String, dynamic>.from(e)),
      ];
    }
    // Old single-bundle shapes: `{prekey: {...}}` or a bare bundle map.
    final bundleMap = map != null && map['prekey'] is Map
        ? Map<String, dynamic>.from(map['prekey'] as Map)
        : map;
    if (bundleMap == null) return const [];
    return [PrekeyBundle.fromJson(bundleMap)];
  }

  /// Per-peer throttle for the decrypt-failure NACK (coord 4c054eab, crit 1).
  /// A locked message re-renders repeatedly, so [reportDecryptFailure] can be
  /// called on every render; this collapses a burst for the same peer to one
  /// POST per [_decryptFailureThrottle] window.
  final Map<String, DateTime> _lastDecryptFailureReport = {};

  /// Minimum spacing between decrypt-failure NACKs for the same peer.
  static const Duration _decryptFailureThrottle = Duration(seconds: 30);

  /// Signal the daemon that a sealed DM could NOT be opened so the sender
  /// re-pulls the reporting device's freshly-republished prekey bundle NOW,
  /// instead of waiting for the 6h TTL re-pull (coord 4c054eab, criterion 1: the
  /// fast-recovery trigger for stale peer keys).
  ///
  /// Direction: the RECIPIENT (this device) failed to open a message from the
  /// SENDER (the daemon we are talking to). It reports so the SENDER re-pulls the
  /// RECIPIENT's own bundle, so [peerShort] is THIS device's own short name and
  /// the daemon re-pulls that peer (the recipient just republished a fresh slot
  /// the sender's cache is missing).
  ///
  /// Best-effort, fire-and-forget: swallows ALL errors (a failed NACK simply
  /// falls back to the TTL re-pull) and NEVER throws, so a locked-bubble render
  /// is never blocked or crashed. Throttled per [peerShort] so a re-render loop
  /// cannot spam the daemon. Returns true only when a POST was actually sent.
  Future<bool> reportDecryptFailure(String peerShort, {String? messageId}) async {
    final key = _peerShort(peerShort);
    final now = DateTime.now();
    final last = _lastDecryptFailureReport[key];
    if (last != null && now.difference(last) < _decryptFailureThrottle) {
      return false;
    }
    _lastDecryptFailureReport[key] = now;
    try {
      await _dio.post('/api/v1/dm/decrypt-failed', data: {
        'peer': key,
        'message_id': ?messageId,
      });
      return true;
    } catch (_) {
      // Best-effort: a failed NACK falls back to the TTL re-pull. Never rethrow.
      return false;
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
    // Guarded KEM: an unavailable PQ backend (no liboqs / no noble) yields a
    // stand-in that fails KEM ops cleanly instead of throwing at construction,
    // so ensureKeyPair() degrades to classical rather than crashing.
    kem: ref.watch(hybridKemProvider),
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
    // Wire the enrolled-device signer (operator PGP identity) so the published
    // bundle is SIGNED. Null until the user completes onboarding / QR login;
    // in that case the bundle publishes unsigned (accepted while the daemon's
    // SKCHAT_REQUIRE_SIGNED_PREKEYS flag is off).
    try {
      svc.bundleSigner = await ref.watch(sovereignSignerProvider.future);
    } catch (_) {
      svc.bundleSigner = null;
    }
    await svc.publish();
  }
  return ok;
});
