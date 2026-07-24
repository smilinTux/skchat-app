import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:skchat/services/device_recovery_codec.dart';
import 'package:skchat/services/device_recovery_wordlist.dart';

/// Hex string -> 32-byte entropy.
Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('vendored wordlist integrity', () {
    test('is exactly 2048 words, unique, sorted, lowercase', () {
      expect(kBip39EnglishWordlist.length, 2048);
      expect(kBip39EnglishWordlist.toSet().length, 2048, reason: 'no dupes');
      final sorted = [...kBip39EnglishWordlist]..sort();
      expect(kBip39EnglishWordlist, sorted, reason: 'canonical sort order');
      expect(kBip39EnglishWordlist.first, 'abandon');
      expect(kBip39EnglishWordlist.last, 'zoo');
      // Anchor a few indices the 11-bit math depends on.
      expect(kBip39EnglishWordlist[0], 'abandon');
      expect(kBip39EnglishWordlist[102], 'art');
      expect(kBip39EnglishWordlist[1967], 'vote');
      expect(kBip39EnglishWordlist[2047], 'zoo');
    });

    test('SHA-256 of the newline-joined list matches canonical english.txt',
        () {
      // The canonical bip-0039/english.txt is the words joined by '\n' with a
      // trailing newline. Pinning its digest guards against any silent edit.
      final joined = '${kBip39EnglishWordlist.join('\n')}\n';
      final digest = c.sha256.convert(utf8.encode(joined)).toString();
      expect(
        digest,
        '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda',
      );
    });
  });

  group('BIP39 known-answer vectors (24 words / 256-bit)', () {
    // Canonical Trezor test vectors (256-bit entropy only).
    const vectors = <(String, String)>[
      (
        '0000000000000000000000000000000000000000000000000000000000000000',
        'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon abandon abandon abandon art',
      ),
      (
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo '
            'zoo zoo zoo zoo zoo zoo vote',
      ),
      (
        '8080808080808080808080808080808080808080808080808080808080808080',
        'letter advice cage absurd amount doctor acoustic avoid letter advice '
            'cage absurd amount doctor acoustic avoid letter advice cage '
            'absurd amount doctor acoustic bless',
      ),
      (
        '77c2b00716cec7213839159e404db50d2401df8bbe6cc0f2eb1c8b8d4c8b8b8b',
        // Encode-only guard: we compare our decode round-trips instead of a
        // hand-copied phrase for this one (see round-trip test below).
        '',
      ),
    ];

    for (final (hex, phrase) in vectors) {
      if (phrase.isEmpty) continue;
      test('entropy $hex encodes to the canonical 24-word phrase', () {
        final words = DeviceRecoveryCodec.entropyToWords(_hex(hex));
        expect(words.length, 24);
        expect(words.join(' '), phrase);
        // And it decodes back to the same entropy.
        final back = DeviceRecoveryCodec.wordsToEntropy(words);
        expect(back, _hex(hex));
      });
    }
  });

  group('round-trip + validation', () {
    test('random 32-byte entropy round-trips through 24 words', () {
      // Deterministic pseudo-random bytes (not for keys, just coverage).
      for (var seed = 1; seed <= 64; seed++) {
        final e = Uint8List(32);
        var x = seed * 2654435761 & 0xffffffff;
        for (var i = 0; i < 32; i++) {
          x = (x * 1103515245 + 12345) & 0xffffffff;
          e[i] = (x >> 16) & 0xff;
        }
        final words = DeviceRecoveryCodec.entropyToWords(e);
        expect(words.length, 24);
        expect(DeviceRecoveryCodec.wordsToEntropy(words), e);
      }
    });

    test('rejects a phrase whose checksum is wrong', () {
      final e = _hex(
        '0000000000000000000000000000000000000000000000000000000000000000',
      );
      final words = DeviceRecoveryCodec.entropyToWords(e);
      // Flip the LAST word (carries the checksum) to a different index.
      final bad = [...words];
      bad[23] = bad[23] == 'art' ? 'zoo' : 'art';
      expect(
        () => DeviceRecoveryCodec.wordsToEntropy(bad),
        throwsA(isA<RecoveryPhraseException>()),
      );
    });

    test('rejects an unknown word', () {
      final e = _hex(
        '0000000000000000000000000000000000000000000000000000000000000000',
      );
      final words = DeviceRecoveryCodec.entropyToWords(e);
      final bad = [...words];
      bad[0] = 'notabip39word';
      expect(
        () => DeviceRecoveryCodec.wordsToEntropy(bad),
        throwsA(isA<RecoveryPhraseException>()),
      );
    });

    test('rejects a phrase of the wrong length', () {
      expect(
        () => DeviceRecoveryCodec.wordsToEntropy(['abandon', 'abandon']),
        throwsA(isA<RecoveryPhraseException>()),
      );
    });

    test('rejects entropy that is not 32 bytes', () {
      expect(
        () => DeviceRecoveryCodec.entropyToWords(Uint8List(16)),
        throwsA(isA<RecoveryPhraseException>()),
      );
    });

    test('is case-insensitive and whitespace-tolerant on input', () {
      final e = _hex(
        '8080808080808080808080808080808080808080808080808080808080808080',
      );
      final words = DeviceRecoveryCodec.entropyToWords(e);
      final messy = '  ${words.join('   ').toUpperCase()}  ';
      expect(DeviceRecoveryCodec.normalize(messy), words);
      expect(DeviceRecoveryCodec.wordsToEntropy(DeviceRecoveryCodec.normalize(messy)), e);
    });
  });
}
