// BIP39 codec for the device recovery phrase (24 words / 256-bit entropy).
//
// The device operator identity is an ECDSA P-256 keypair whose private key is
// a 32-byte big-endian scalar `d` (see guest_identity_io.dart, which stores
// `base64(_bytes32(priv.d))`). Those exact 32 bytes ARE the BIP39 entropy, so
// the recovery phrase encodes the private key with a checksum and no other
// derivation: `words -> entropy -> scalar d` reproduces the same keypair.
//
// This is a self-contained BIP39 implementation over the vendored wordlist
// (device_recovery_wordlist.dart); we deliberately do NOT add a bip39 pub
// dependency, matching this repo's sovereign / vendored crypto philosophy.
//
// Scope: encoding/decoding + checksum only. Range-validating the decoded
// scalar as a P-256 private key (1 <= d < n) is the CALLER's job
// (guest_identity_io.dart), because a checksum-valid phrase can still decode
// to d == 0 or d >= n.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'device_recovery_wordlist.dart';

/// Thrown for any malformed recovery phrase or entropy: wrong length, unknown
/// word, or a failed BIP39 checksum. The message is safe to show a user.
class RecoveryPhraseException implements Exception {
  const RecoveryPhraseException(this.message);
  final String message;
  @override
  String toString() => 'RecoveryPhraseException: $message';
}

/// Stateless BIP39 codec pinned to 256-bit entropy (24 words), big-endian.
class DeviceRecoveryCodec {
  DeviceRecoveryCodec._();

  /// Bytes of entropy this codec operates on (P-256 scalar width).
  static const int entropyBytes = 32; // ENT = 256 bits
  static const int _wordCount = 24; // (256 + 256/32) / 11
  static const int _checksumBits = entropyBytes * 8 ~/ 32; // 8

  /// Reverse index: word -> BIP39 value. Built once, lazily.
  static final Map<String, int> _index = () {
    final m = <String, int>{};
    for (var i = 0; i < kBip39EnglishWordlist.length; i++) {
      m[kBip39EnglishWordlist[i]] = i;
    }
    return m;
  }();

  /// Encode 32 bytes of entropy to the canonical 24-word BIP39 phrase.
  static List<String> entropyToWords(Uint8List entropy) {
    if (entropy.length != entropyBytes) {
      throw RecoveryPhraseException(
        'entropy must be $entropyBytes bytes, got ${entropy.length}',
      );
    }
    // bit string = entropy bits (MSB-first) ++ first `_checksumBits` of
    // SHA-256(entropy).
    final checksum = c.sha256.convert(entropy).bytes;
    final totalBits = entropyBytes * 8 + _checksumBits;

    bool bitAt(int i) {
      if (i < entropyBytes * 8) {
        return (entropy[i >> 3] >> (7 - (i & 7))) & 1 == 1;
      }
      final j = i - entropyBytes * 8; // into the checksum byte(s)
      return (checksum[j >> 3] >> (7 - (j & 7))) & 1 == 1;
    }

    final words = <String>[];
    for (var w = 0; w < _wordCount; w++) {
      var v = 0;
      for (var b = 0; b < 11; b++) {
        final bitIndex = w * 11 + b;
        v = (v << 1) | (bitIndex < totalBits && bitAt(bitIndex) ? 1 : 0);
      }
      words.add(kBip39EnglishWordlist[v]);
    }
    return words;
  }

  /// Decode a 24-word BIP39 phrase back to 32 bytes of entropy, validating the
  /// checksum. Throws [RecoveryPhraseException] on any error.
  static Uint8List wordsToEntropy(List<String> words) {
    if (words.length != _wordCount) {
      throw RecoveryPhraseException(
        'expected $_wordCount words, got ${words.length}',
      );
    }
    final totalBits = entropyBytes * 8 + _checksumBits;
    final bits = List<bool>.filled(totalBits, false);
    for (var w = 0; w < _wordCount; w++) {
      final word = words[w];
      final v = _index[word];
      if (v == null) {
        throw RecoveryPhraseException('not a recovery word: "$word"');
      }
      for (var b = 0; b < 11; b++) {
        bits[w * 11 + b] = (v >> (10 - b)) & 1 == 1;
      }
    }

    final entropy = Uint8List(entropyBytes);
    for (var i = 0; i < entropyBytes * 8; i++) {
      if (bits[i]) entropy[i >> 3] |= 1 << (7 - (i & 7));
    }

    // Recompute + compare the checksum bits.
    final checksum = c.sha256.convert(entropy).bytes;
    for (var i = 0; i < _checksumBits; i++) {
      final want = (checksum[i >> 3] >> (7 - (i & 7))) & 1 == 1;
      if (bits[entropyBytes * 8 + i] != want) {
        throw const RecoveryPhraseException(
          'recovery phrase checksum failed (a word is wrong or out of order)',
        );
      }
    }
    return entropy;
  }

  /// Normalize free-form user input into a clean lowercase word list: trims,
  /// lowercases, and collapses any run of whitespace. Does NOT validate.
  static List<String> normalize(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
  }
}
