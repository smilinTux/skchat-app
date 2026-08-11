@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Import gate as a runnable test (card C-2, module contract standard section
/// 3.1: "a grep gate proves the module's UI package imports only
/// skworld_module_api, never any shell package"), so `flutter test` alone
/// enforces the boundary without needing a shell. Mirrors
/// `tool/import_gate.sh` and `packages/skchat_ui/test/import_gate_test.dart`.
///
/// Scans every `.dart` under this package's `lib/` and asserts each
/// `package:` import/export targets only the allowed set: `package:flutter/`,
/// `package:skworld_module_api/`, or `package:skcode_client/` (self). `dart:`
/// and relative imports are always fine. Any other `package:` (a shell
/// package, the app `package:skchat/`, a subapp) is a boundary violation.
void main() {
  test('skcode_client/lib imports only skworld_module_api + flutter/dart core',
      () {
    // Test cwd is the package root under `flutter test`.
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: 'run from the skcode_client package root');

    final allowed = RegExp(
      r"package:(flutter|skworld_module_api|skcode_client)/",
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
      reason: 'skcode_client/lib may import only flutter, skworld_module_api '
          'and itself. Boundary violations:\n${violations.join('\n')}',
    );
  });
}
