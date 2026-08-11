// Font-literal ratchet guard (density spec section 7.1).
//
// Pure Dart, no Flutter plugin: scans `lib/` and `packages/` for
// `fontSize:` followed by a numeric literal, and for
// `textScaler: TextScaler.noScaling` / `textScaleFactor` (the OS
// accessibility-scaling invariant, density spec section 5).
//
// Allowed zones: `packages/skchat_ui/lib/src/theme/` (the token
// definitions themselves) plus an explicit allowlist
// (`tool/font_literal_allowlist.txt`) of exact `path:trimmed-line-content`
// entries for genuinely decorative cases.
//
// Ratchet, not big bang: `tool/font_literal_baseline.txt` lists today's
// pre-existing literals as `path:literal` entries (one line per
// occurrence, so a literal repeated N times in one file appears N times).
// This test fails on:
//   1. any `fontSize:`/`TextScaler.noScaling`/`textScaleFactor` occurrence
//      NOT covered by baseline or allowlist (a NEW literal, red), and
//   2. any baseline entry that no longer has a matching occurrence (a
//      STALE entry, forcing the baseline to shrink as the burn-down, card
//      D-2, lands). The baseline can only shrink, never grow.
//
// The burn-down itself (replacing the 300+ pre-existing literals with
// SovereignTypography roles, including the new `micro`/`badge`) is D-2,
// not this card. This guard only stops the count from getting worse.
import 'dart:io';

// Uses only the `test`-style assertion API (expect/group/test), re-exported
// by flutter_test. No widget pumping, no Flutter plugin: this is a pure
// static scan of the .dart source tree, run via `flutter test` because
// that is this repo's one test entry point.
import 'package:flutter_test/flutter_test.dart';

/// Directories scanned, relative to the repo root.
const _scannedDirs = ['lib', 'packages'];

/// Zones exempt from the fontSize-literal ban (but NOT from the
/// TextScaler/textScaleFactor ban, which is enforced app-wide).
const _allowedZones = ['packages/skchat_ui/lib/src/theme/'];

final _fontSizeLiteral = RegExp(r'fontSize:\s*(-?\d+(?:\.\d+)?)');
final _noScaling = RegExp(r'TextScaler\.noScaling');
final _textScaleFactor = RegExp(r'\btextScaleFactor\b');

// Strips a trailing `//` line comment before matching, so a doc comment
// that merely EXPLAINS the banned APIs (this file's own header, or a
// warning comment elsewhere) doesn't trip the guard. The negative
// lookbehind protects `https://` (and similar `scheme://`) string literals
// from being cut mid-string.
final _lineComment = RegExp(r'(?<!:)//.*$');

String _stripLineComment(String line) => line.replaceFirst(_lineComment, '');

/// Walks up from the test file's own directory to find the repo root
/// (identified by `pubspec.yaml`), so the test works regardless of the
/// working directory `flutter test`/`dart test` is invoked from.
Directory _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate repo root (no pubspec.yaml+lib/ '
          'found walking up from ${Directory.current.path})');
    }
    dir = parent;
  }
}

/// Loads non-empty, non-comment (`#`) lines from [path], or an empty list
/// if the file does not exist.
List<String> _loadLines(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  return file
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
}

Map<String, int> _counts(Iterable<String> entries) {
  final map = <String, int>{};
  for (final e in entries) {
    map[e] = (map[e] ?? 0) + 1;
  }
  return map;
}

void main() {
  test(
    'no new fontSize literal outside theme roles; baseline only shrinks; '
    'TextScaler.noScaling / textScaleFactor never appear',
    () {
      final repoRoot = _findRepoRoot();
      final baseline =
          _loadLines('${repoRoot.path}/tool/font_literal_baseline.txt');
      final allowlist =
          _loadLines('${repoRoot.path}/tool/font_literal_allowlist.txt')
              .toSet();

      final currentLiterals = <String>[]; // 'path:literal' occurrences
      final scaleViolations = <String>[];

      for (final dirName in _scannedDirs) {
        final root = Directory('${repoRoot.path}/$dirName');
        if (!root.existsSync()) continue;

        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;

          final relPath = entity.path
              .substring(repoRoot.path.length + 1)
              .replaceAll(r'\', '/');
          final inAllowedZone =
              _allowedZones.any((zone) => relPath.startsWith(zone));

          final lines = entity.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            final rawLine = lines[i];
            final trimmed = rawLine.trim();
            final lineKey = '$relPath:$trimmed';
            if (allowlist.contains(lineKey)) continue;

            final code = _stripLineComment(rawLine);

            // Accessibility invariant: zero tolerance, in every zone,
            // including the theme package itself.
            if (_noScaling.hasMatch(code) || _textScaleFactor.hasMatch(code)) {
              scaleViolations.add('$relPath:${i + 1}: $trimmed');
              continue;
            }

            if (inAllowedZone) continue;

            final match = _fontSizeLiteral.firstMatch(code);
            if (match != null) {
              currentLiterals.add('$relPath:${match.group(1)}');
            }
          }
        }
      }

      expect(
        scaleViolations,
        isEmpty,
        reason: 'Never bypass OS accessibility text scaling. Density sets '
            'BASE sizes; MediaQuery.textScaler multiplies on top for every '
            'Text that does not override it. Found forbidden '
            'TextScaler.noScaling / textScaleFactor usage:\n'
            '${scaleViolations.join('\n')}',
      );

      final baselineCounts = _counts(baseline);
      final currentCounts = _counts(currentLiterals);

      final newEntries = <String>[];
      currentCounts.forEach((key, count) {
        final allowed = baselineCounts[key] ?? 0;
        if (count > allowed) {
          newEntries.add('$key (found $count, baseline allows $allowed)');
        }
      });

      final staleEntries = <String>[];
      baselineCounts.forEach((key, count) {
        final actual = currentCounts[key] ?? 0;
        if (count > actual) {
          staleEntries.add('$key (baseline has $count, actual $actual)');
        }
      });

      expect(
        newEntries,
        isEmpty,
        reason: 'New fontSize literal(s) found outside '
            'packages/skchat_ui/lib/src/theme/. Use a SovereignTypography '
            'role instead (including the micro/badge roles, which exist '
            'exactly so small literals have somewhere legal to land), or '
            'add a precise path:line-content entry to '
            'tool/font_literal_allowlist.txt for a genuinely decorative '
            'case:\n${newEntries.join('\n')}',
      );

      expect(
        staleEntries,
        isEmpty,
        reason: 'tool/font_literal_baseline.txt has stale entries: the '
            'ratchet can only shrink. Remove entries for literals that no '
            'longer exist (burn-down landed) from the baseline file:\n'
            '${staleEntries.join('\n')}',
      );
    },
  );
}
