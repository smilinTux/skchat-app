// A stable, symmetric safety number for out-of-band peer verification. Both
// sides compute the SAME value by sorting the two fingerprints before hashing,
// so direction does not matter. This is an ADVISORY continuity check (it proves
// both sides hold the same two fingerprint strings), not a full authenticated
// key agreement.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Uint8List _digest(String a, String b) {
  final pair = [a, b]..sort();
  return Uint8List.fromList(
      sha256.convert(utf8.encode('${pair[0]}|${pair[1]}')).bytes);
}

/// A 60-digit decimal safety number rendered as 12 space-separated groups of 5.
/// Derived from 30 bytes of the digest, 5 digits per byte-pair chunk.
String safetyNumber(String selfFingerprint, String peerFingerprint) {
  final d = _digest(selfFingerprint, peerFingerprint);
  final sb = StringBuffer();
  // 12 groups of 5 digits: take a rolling 4-byte window per group, mod 100000.
  for (var g = 0; g < 12; g++) {
    var v = 0;
    for (var i = 0; i < 4; i++) {
      v = (v << 8) | d[(g * 4 + i) % d.length];
    }
    final group = (v % 100000).toString().padLeft(5, '0');
    if (g > 0) sb.write(' ');
    sb.write(group);
  }
  return sb.toString();
}

/// A short uppercase-hex compare code (first 4 digest bytes) for compact UI.
String safetyCompareCode(String a, String b) {
  final d = _digest(a, b);
  return d
      .sublist(0, 4)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}
