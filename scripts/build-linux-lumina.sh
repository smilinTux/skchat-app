#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
flutter build linux --release --dart-define-from-file=config/lumina.json
echo "built build/linux/x64/release/bundle (operator build -> .158)"
