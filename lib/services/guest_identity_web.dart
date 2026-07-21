// Web implementation of GuestIdentity using the browser WebCrypto API
// (crypto.subtle) via dart:js_interop + window.localStorage.
//
// We generate an ECDSA P-256 keypair, persist BOTH keys as JWK in localStorage
// (so the same browser keeps the same identity across reloads), export the
// public key as base64 SPKI for the server, and sign messages with
// ECDSA(SHA-256). Signatures are advisory: they prove same-browser continuity,
// not capauth-verified identity.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'guest_identity.dart';

const _kPrivKey = 'skchat.guest.privJwk';
const _kPubKey = 'skchat.guest.pubJwk';

GuestIdentity createGuestIdentity() => _WebGuestIdentity();

// ── Minimal SubtleCrypto JS interop (only what we use) ─────────────────────
@JS('crypto.subtle')
external _SubtleCrypto get _subtle;

extension type _SubtleCrypto._(JSObject _) implements JSObject {
  external JSPromise<JSObject> generateKey(
      JSObject algorithm, bool extractable, JSArray<JSString> keyUsages);
  external JSPromise<JSObject> exportKey(String format, JSObject key);
  external JSPromise<JSObject> importKey(String format, JSObject keyData,
      JSObject algorithm, bool extractable, JSArray<JSString> keyUsages);
  external JSPromise<JSArrayBuffer> sign(
      JSObject algorithm, JSObject key, JSArrayBuffer data);
  external JSPromise<JSArrayBuffer> digest(JSObject algorithm, JSArrayBuffer data);
}

extension type _CryptoKeyPair._(JSObject _) implements JSObject {
  external JSObject get privateKey;
  external JSObject get publicKey;
}

class _WebGuestIdentity implements GuestIdentity {
  GuestKeypair? _cached;

  @override
  Future<bool> hasCached() async =>
      web.window.localStorage.getItem(_kPrivKey) != null &&
      web.window.localStorage.getItem(_kPubKey) != null;

  @override
  Future<GuestKeypair> ensure() async {
    if (_cached != null) return _cached!;

    try {
      if (await hasCached()) {
        final pubJwk = _jsonToJs(web.window.localStorage.getItem(_kPubKey)!);
        final pubB64 = await _exportSpkiFromJwk(pubJwk);
        final fp = await _fingerprint(pubB64);
        return _cached = GuestKeypair(publicKeyB64: pubB64, fingerprint: fp);
      }

      final algo = _obj({'name': 'ECDSA'.toJS, 'namedCurve': 'P-256'.toJS});
      final pair = _CryptoKeyPair._(
        await _subtle
            .generateKey(algo, true, ['sign'.toJS, 'verify'.toJS].toJS)
            .toDart,
      );

      final privJwk = await _subtle.exportKey('jwk', pair.privateKey).toDart;
      final pubJwk = await _subtle.exportKey('jwk', pair.publicKey).toDart;
      web.window.localStorage.setItem(_kPrivKey, _jsToJson(privJwk));
      web.window.localStorage.setItem(_kPubKey, _jsToJson(pubJwk));

      final pubB64 = await _exportSpki(pair.publicKey);
      final fp = await _fingerprint(pubB64);
      return _cached = GuestKeypair(publicKeyB64: pubB64, fingerprint: fp);
    } catch (_) {
      // Privacy browser blocked localStorage and/or crypto.subtle. Fall back
      // to a unique in-memory keypair surrogate so the user still gets a
      // distinct id (no collision) and can join, flagged degraded so the UI
      // can warn it will not persist across a reload. Deliberately does NOT
      // touch localStorage or crypto.subtle again here.
      final rnd = math.Random.secure();
      final rawPub = List<int>.generate(32, (_) => rnd.nextInt(256));
      final pubB64 = base64Encode(rawPub);
      final rawFp = List<int>.generate(8, (_) => rnd.nextInt(256));
      final fp = rawFp.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return _cached =
          GuestKeypair(publicKeyB64: pubB64, fingerprint: fp, degraded: true);
    }
  }

  @override
  Future<String> sign(String data) async {
    if (web.window.localStorage.getItem(_kPrivKey) == null) {
      await ensure();
    }
    final privJwk = _jsonToJs(web.window.localStorage.getItem(_kPrivKey)!);
    final importAlgo = _obj({'name': 'ECDSA'.toJS, 'namedCurve': 'P-256'.toJS});
    final privKey = await _subtle
        .importKey('jwk', privJwk, importAlgo, false, ['sign'.toJS].toJS)
        .toDart;
    final signAlgo = _obj({
      'name': 'ECDSA'.toJS,
      'hash': _obj({'name': 'SHA-256'.toJS}),
    });
    final buf = _bytesToBuffer(Uint8List.fromList(utf8.encode(data)));
    final sig = await _subtle.sign(signAlgo, privKey, buf).toDart;
    return base64Encode(sig.toDart.asUint8List());
  }

  @override
  Future<void> clear() async {
    web.window.localStorage.removeItem(_kPrivKey);
    web.window.localStorage.removeItem(_kPubKey);
    _cached = null;
  }

  // ── helpers ──────────────────────────────────────────────────────────────
  Future<String> _exportSpki(JSObject pubKey) async {
    final spki = await _subtle.exportKey('spki', pubKey).toDart;
    return base64Encode((spki as JSArrayBuffer).toDart.asUint8List());
  }

  Future<String> _exportSpkiFromJwk(JSObject jwk) async {
    final importAlgo = _obj({'name': 'ECDSA'.toJS, 'namedCurve': 'P-256'.toJS});
    final pubKey = await _subtle
        .importKey('jwk', jwk, importAlgo, true, ['verify'.toJS].toJS)
        .toDart;
    return _exportSpki(pubKey);
  }

  Future<String> _fingerprint(String spkiB64) async {
    final buf = _bytesToBuffer(Uint8List.fromList(utf8.encode(spkiB64)));
    final digest =
        await _subtle.digest(_obj({'name': 'SHA-256'.toJS}), buf).toDart;
    final hex = digest.toDart
        .asUint8List()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return hex.substring(0, 16);
  }

  JSObject _obj(Map<String, JSAny> entries) {
    final o = JSObject();
    entries.forEach((k, v) => o.setProperty(k.toJS, v));
    return o;
  }

  JSArrayBuffer _bytesToBuffer(Uint8List bytes) => bytes.buffer.toJS;

  // JWK <-> JSON via the browser's JSON so the stored shape is canonical.
  String _jsToJson(JSObject jsObj) =>
      _jsonStringify(jsObj);
  JSObject _jsonToJs(String json) => _jsonParse(json) as JSObject;
}

@JS('JSON.stringify')
external String _jsonStringify(JSObject value);

@JS('JSON.parse')
external JSAny _jsonParse(String text);
