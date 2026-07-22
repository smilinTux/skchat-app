#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/cbrd21/flutter/bin:$PATH
cd "$(dirname "$0")/.."
flutter build web --release --base-href /app/ --pwa-strategy=none \
  --dart-define-from-file=config/lumina.json
echo "built web (lumina). rsync into skchat/src/skchat/static/app/ then restart skchat-webui@lumina"
