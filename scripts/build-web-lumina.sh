#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
# Build stamp so a device can confirm which build it runs (past PWA/SW cache).
APP_VERSION="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"
BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)-$(date +%m%d-%H%M)"
echo "build stamp: v$APP_VERSION build $BUILD_ID"
flutter build web --release --base-href /app/ --pwa-strategy=none \
  --dart-define-from-file=config/lumina.json \
  --dart-define="APP_VERSION=$APP_VERSION" \
  --dart-define="BUILD_ID=$BUILD_ID"
echo "built web (lumina). rsync into skchat/src/skchat/static/app/ then restart skchat-webui@lumina"
