#!/usr/bin/env bash
# Run the skchat integration_test suite on the Linux desktop device.
#
# Wraps `flutter test integration_test -d linux` with the environment a real
# X display needs, so an agent can run it non-interactively over SSH on the
# test node, e.g.:
#
#   ssh 192.168.0.41 'DISPLAY=:0 ~/path/to/skchat-app/scripts/run-integration-tests.sh'
#
# Env knobs (all optional):
#   DISPLAY          X display to render on (default :0)
#   SKCHAT_IT_LIVE   set to 1 to run against a live SKChat web UI + LiveKit
#                    server instead of the in-process fakes; mapped to
#                    --dart-define=SKCHAT_IT_LIVE=true (see
#                    integration_test/spaces_flow_test.dart header)
#   FLUTTER_BIN      path to the flutter binary (default: flutter on PATH,
#                    falling back to ~/flutter/bin/flutter)
#
# Any extra arguments are passed through to `flutter test`, e.g.:
#   ./scripts/run-integration-tests.sh --name "app boots"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve flutter without requiring an interactive login shell.
FLUTTER_BIN="${FLUTTER_BIN:-}"
if [ -z "$FLUTTER_BIN" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="flutter"
  elif [ -x "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_BIN="$HOME/flutter/bin/flutter"
  else
    echo "flutter not found; set FLUTTER_BIN or add flutter to PATH" >&2
    exit 1
  fi
fi

# Real X display for the linux desktop embedder. Over SSH there is usually no
# DISPLAY inherited, so default to the console display.
export DISPLAY="${DISPLAY:-:0}"

# XDG_RUNTIME_DIR is unset on some non-login SSH sessions; GTK wants it.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Never block on analytics/first-run prompts.
export CI=true

EXTRA_ARGS=()
if [ "${SKCHAT_IT_LIVE:-0}" = "1" ]; then
  EXTRA_ARGS+=(--dart-define=SKCHAT_IT_LIVE=true)
fi

cd "$PROJECT_DIR"

echo "== skchat integration tests =="
echo "project:  $PROJECT_DIR"
echo "display:  $DISPLAY"
echo "live:     ${SKCHAT_IT_LIVE:-0}"

"$FLUTTER_BIN" pub get

exec "$FLUTTER_BIN" test integration_test -d linux \
  --reporter expanded \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
  "$@"
