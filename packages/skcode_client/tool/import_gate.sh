#!/usr/bin/env bash
# Import gate (card C-2, module contract standard section 3.1: "a grep gate
# proves the module's UI package imports only skworld_module_api, never any
# shell package"), mirroring packages/skchat_ui/tool/import_gate.sh.
#
# Proves packages/skcode_client/lib imports ONLY:
#   - package:flutter/...             (Flutter widget/theme primitives)
#   - dart:...                        (Dart core)
#   - package:skworld_module_api/...  (the UI-facet contract)
#   - package:skcode_client/...       (self-reference)
#   - relative imports                (within this package's own lib/)
#
# Any other package: import (a shell package, the app `package:skchat/...`,
# a subapp, etc.) is a boundary violation and fails the gate.
#
# Usage: packages/skcode_client/tool/import_gate.sh
# Exit 0 = clean, exit 1 = violation(s) found.
set -euo pipefail

pkg_dir="$(cd "$(dirname "$0")/.." && pwd)"
lib_dir="$pkg_dir/lib"

# Every import/export whose target is a package: URI.
offenders="$(grep -rhnE "^\s*(import|export)\s+'package:" "$lib_dir" \
  | grep -vE "package:(flutter|skworld_module_api|skcode_client)/" \
  || true)"

if [[ -n "$offenders" ]]; then
  echo "FAIL: skcode_client/lib imports a package outside the allowed set" >&2
  echo "  (allowed: flutter, skworld_module_api, skcode_client, dart:, relative)" >&2
  echo "$offenders" >&2
  exit 1
fi

echo "OK: skcode_client/lib imports only skworld_module_api + flutter/dart core"
