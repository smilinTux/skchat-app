#!/usr/bin/env bash
# Standalone import gate (card C-2, "ZERO shell imports"), mirroring
# apps/skchat_standalone/tool/standalone_import_gate.sh.
#
# Proves apps/skcode_standalone/lib imports ONLY:
#   - package:flutter/...             (Flutter widget/theme primitives)
#   - dart:...                        (Dart core)
#   - package:skworld_module_api/...  (the UI-facet contract)
#   - package:skcode_client/...       (the subapp UI facet it runs)
#   - package:skcode_standalone/...   (self-reference)
#   - relative imports                (within this package's own lib/)
#
# Any other package: import, above all the app shell package `package:skchat/`,
# is a boundary violation and fails the gate. The standalone runner must never
# reach back into the shell.
#
# Usage: apps/skcode_standalone/tool/standalone_import_gate.sh
# Exit 0 = clean, exit 1 = violation(s) found.
set -euo pipefail

pkg_dir="$(cd "$(dirname "$0")/.." && pwd)"
lib_dir="$pkg_dir/lib"

offenders="$(grep -rhnE "^\s*(import|export)\s+'package:" "$lib_dir" \
  | grep -vE "package:(flutter|skworld_module_api|skcode_client|skcode_standalone)/" \
  || true)"

if [[ -n "$offenders" ]]; then
  echo "FAIL: skcode_standalone/lib imports a package outside the allowed set" >&2
  echo "  (allowed: flutter, skworld_module_api, skcode_client, skcode_standalone, dart:, relative)" >&2
  echo "  in particular it must NOT import the app shell package package:skchat/" >&2
  echo "$offenders" >&2
  exit 1
fi

echo "OK: skcode_standalone/lib imports only skcode_client + skworld_module_api + flutter/dart core"
