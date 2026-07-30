@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Import gate as a runnable test (reconciled spec 3.2 step 4), so
/// `flutter test` alone enforces the boundary without needing a shell. Mirrors
/// `tool/import_gate.sh`.
///
/// Scans every `.dart` under this package's `lib/` and asserts each
/// `package:` import/export targets only the allowed set: `package:flutter/`,
/// `package:skworld_module_api/`, or `package:skchat_ui/` (self). `dart:` and
/// relative imports are always fine. Any other `package:` (a shell package, the
/// app `package:skchat/`, a subapp) is a boundary violation.
void main() {
  test('skchat_ui/lib imports only skworld_module_api + flutter/dart core', () {
    // Test cwd is the package root under `flutter test`.
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: 'run from the skchat_ui package root');

    final allowed = RegExp(
      r"package:(flutter|skworld_module_api|skchat_ui)/",
    );
    final packageImport = RegExp(
      r"""^\s*(?:import|export)\s+'package:([^']+)'""",
    );

    final violations = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!packageImport.hasMatch(line)) continue;
        if (allowed.hasMatch(line)) continue;
        violations.add('${entity.path}:${i + 1}: ${line.trim()}');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'skchat_ui/lib may import only flutter, skworld_module_api and '
          'itself. Boundary violations:\n${violations.join('\n')}',
    );
  });
}
