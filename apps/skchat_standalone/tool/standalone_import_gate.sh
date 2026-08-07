#!/usr/bin/env bash
# Standalone import gate (reconciled spec 3.2 step 3: "ZERO shell imports").
#
# Proves apps/skchat_standalone/lib imports ONLY:
#   - package:flutter/...            (Flutter widget/theme primitives)
#   - dart:...                       (Dart core)
#   - package:skworld_module_api/... (the UI-facet contract)
#   - package:skchat_ui/...          (the subapp UI facet it runs)
#   - package:skchat_standalone/...  (self-reference)
#   - relative imports               (within this package's own lib/)
#
# Any other package: import, above all the app shell package `package:skchat/`,
# is a boundary violation and fails the gate. The standalone runner is what
# deploys to :8088; it must never reach back into the shell.
#
# Usage: apps/skchat_standalone/tool/standalone_import_gate.sh
# Exit 0 = clean, exit 1 = violation(s) found.
set -euo pipefail

pkg_dir="$(cd "$(dirname "$0")/.." && pwd)"
lib_dir="$pkg_dir/lib"

offenders="$(grep -rhnE "^\s*(import|export)\s+'package:" "$lib_dir" \
  | grep -vE "package:(flutter|skworld_module_api|skchat_ui|skchat_standalone)/" \
  || true)"

if [[ -n "$offenders" ]]; then
  echo "FAIL: skchat_standalone/lib imports a package outside the allowed set" >&2
  echo "  (allowed: flutter, skworld_module_api, skchat_ui, skchat_standalone, dart:, relative)" >&2
  echo "  in particular it must NOT import the app shell package package:skchat/" >&2
  echo "$offenders" >&2
  exit 1
fi

echo "OK: skchat_standalone/lib imports only skchat_ui + skworld_module_api + flutter/dart core"
