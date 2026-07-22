#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
flutter build linux --release
echo "built build/linux/x64/release/bundle (neutral: user picks server at first run)"
