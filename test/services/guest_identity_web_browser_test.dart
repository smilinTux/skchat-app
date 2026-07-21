// Browser-only test for the REAL _WebGuestIdentity.ensure() fallback path in
// guest_identity_web.dart. This file imports dart:js_interop (transitively,
// via package:web) so it cannot run on the VM test runner; it is tagged
// "browser" and must run under a real browser environment:
//
//   export PATH=/home/cbrd21/flutter/bin:$PATH
//   flutter test test/services/guest_identity_web_browser_test.dart --platform chrome
//
// It simulates a privacy browser blocking localStorage by monkey-patching
// Storage.prototype.getItem/setItem to throw for the duration of the test,
// then restores the originals so it does not leak into other tests.
@TestOn("browser")
@Tags(["browser"])
library;

import "dart:js_interop";
import "dart:js_interop_unsafe";

import "package:flutter_test/flutter_test.dart";
import "package:skchat/services/guest_identity.dart";
import "package:skchat/services/guest_identity_web.dart" as impl;
import "package:web/web.dart" as web;

@JS("Storage.prototype")
external JSObject get _storageProto;

JSAny? _throwBlocked([JSAny? a, JSAny? b]) {
  throw Exception("blocked: privacy mode simulated storage failure");
}

void main() {
  group("_WebGuestIdentity.ensure() storage failure", () {
    late JSAny? originalGetItem;
    late JSAny? originalSetItem;

    setUp(() {
      originalGetItem = _storageProto.getProperty("getItem".toJS);
      originalSetItem = _storageProto.getProperty("setItem".toJS);
      _storageProto.setProperty("getItem".toJS, _throwBlocked.toJS);
      _storageProto.setProperty("setItem".toJS, _throwBlocked.toJS);
    });

    tearDown(() {
      _storageProto.setProperty("getItem".toJS, originalGetItem);
      _storageProto.setProperty("setItem".toJS, originalSetItem);
    });

    test(
        "returns a unique in-memory keypair marked degraded instead of throwing",
        () async {
      final a = await impl.createGuestIdentity().ensure();
      final b = await impl.createGuestIdentity().ensure();

      expect(a.degraded, isTrue);
      expect(a.publicKeyB64, isNotEmpty);
      expect(a.fingerprint, isNotEmpty);
      // Unique per call, never a constant fallback value.
      expect(a.publicKeyB64, isNot(equals(b.publicKeyB64)));
      expect(a.fingerprint, isNot(equals(b.fingerprint)));
    });
  });

  group("_WebGuestIdentity.ensure() happy path (storage available)", () {
    test("returns a non-degraded keypair and persists it", () async {
      web.window.localStorage.clear();
      final GuestKeypair k = await impl.createGuestIdentity().ensure();
      expect(k.degraded, isFalse);
      expect(k.publicKeyB64, isNotEmpty);
      web.window.localStorage.clear();
    });
  });
}
