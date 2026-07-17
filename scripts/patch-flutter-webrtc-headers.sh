#!/usr/bin/env bash
# Idempotent fix for flutter_webrtc's bundled libwebrtc headers missing
# transitive stdint includes under newer GCC (16.1.1 tested on 192.168.0.41).
#
# Symptom: build fails with errors like
#   rtc_types.h:98:3: error: unknown type name 'uint32_t'
# because the bundled headers use fixed-width integer types (uint8_t,
# uint16_t, uint32_t, uint64_t, size_t, etc) without including <stdint.h>,
# relying on an older GCC/libstdc++ to pull it in transitively.
#
# This script inserts "#include <stdint.h>" right after each header's
# include guard (the #ifndef / #define pair), or before the first existing
# #include if no guard is found. It is safe to re-run: any header that
# already includes <stdint.h> or <cstdint> is left untouched.
#
# pubspec.yaml pins flutter_webrtc to a range (currently
# ">=0.14.0 <2.0.0"), so the exact resolved version can drift between `flutter
# pub get` runs. Rather than hardcode a version directory, this script reads
# the version pub actually resolved from pubspec.lock next to this script's
# repo root, falling back to a glob of the pub cache if the lock is
# unavailable or unparsable. Override with FLUTTER_WEBRTC_VERSION to force a
# specific version.
#
# Usage:
#   bash patch-flutter-webrtc-headers.sh
# Run this on the machine that owns the pub cache (eg 192.168.0.41), since
# the flutter plugin symlinks its ephemeral headers back into the pub cache.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PUB_ROOT="${PUB_ROOT:-$HOME/.pub-cache/hosted/pub.dev}"
LOCK_FILE="${LOCK_FILE:-$REPO_ROOT/pubspec.lock}"

resolve_version() {
  # 1. Explicit override.
  if [ -n "${FLUTTER_WEBRTC_VERSION:-}" ]; then
    echo "$FLUTTER_WEBRTC_VERSION"
    return 0
  fi

  # 2. Read the version pub actually resolved, from the flutter_webrtc block
  #    in pubspec.lock (the "name: flutter_webrtc" entry, not
  #    flutter_webrtc_platform_interface or similar lookalikes).
  if [ -f "$LOCK_FILE" ]; then
    local v
    v="$(awk '
      /^  [a-zA-Z0-9_]+:$/ { in_pkg = 0 }
      /^  flutter_webrtc:$/ { in_pkg = 1; next }
      in_pkg && /^      name: flutter_webrtc$/ { name_ok = 1; next }
      in_pkg && /^    version: / {
        if (name_ok) {
          v = $0
          sub(/^    version: "?/, "", v)
          sub(/"$/, "", v)
          print v
          exit
        }
      }
    ' "$LOCK_FILE")"
    if [ -n "$v" ]; then
      echo "$v"
      return 0
    fi
  fi

  # 3. Fall back to whatever single flutter_webrtc-* directory is in the pub
  #    cache. If there is more than one (stale versions left over from a
  #    prior resolution), refuse to guess.
  local matches=()
  if [ -d "$PUB_ROOT" ]; then
    for d in "$PUB_ROOT"/flutter_webrtc-*/; do
      [ -d "$d" ] || continue
      matches+=("$(basename "$d")")
    done
  fi
  if [ "${#matches[@]}" -eq 1 ]; then
    echo "${matches[0]#flutter_webrtc-}"
    return 0
  fi

  return 1
}

PKG_VERSION="$(resolve_version || true)"
if [ -z "$PKG_VERSION" ]; then
  echo "Could not resolve the installed flutter_webrtc version." >&2
  echo "Tried: FLUTTER_WEBRTC_VERSION env, $LOCK_FILE, and a unique" >&2
  echo "flutter_webrtc-*/ glob under $PUB_ROOT." >&2
  echo "Run 'flutter pub get' first, or set FLUTTER_WEBRTC_VERSION explicitly." >&2
  exit 1
fi

PKG_DIR="$PUB_ROOT/flutter_webrtc-$PKG_VERSION/third_party/libwebrtc/include"

if [ ! -d "$PKG_DIR" ]; then
  echo "flutter_webrtc include dir not found at: $PKG_DIR" >&2
  echo "(resolved version: $PKG_VERSION)" >&2
  echo "Set PUB_ROOT to override the pub cache location, or" >&2
  echo "FLUTTER_WEBRTC_VERSION to override the resolved version." >&2
  exit 1
fi

# Headers confirmed (2026-07-17, GCC 16.1.1) to use fixed-width integer
# types without including stdint.h themselves.
FILES=(
  "$PKG_DIR/rtc_types.h"
  "$PKG_DIR/rtc_rtp_parameters.h"
  "$PKG_DIR/rtc_desktop_capturer.h"
  "$PKG_DIR/rtc_peerconnection.h"
  "$PKG_DIR/rtc_video_frame.h"
  "$PKG_DIR/rtc_audio_source.h"
  "$PKG_DIR/base/portable.h"
  "$PKG_DIR/rtc_audio_frame.h"
  "$PKG_DIR/rtc_video_device.h"
  "$PKG_DIR/rtc_desktop_media_list.h"
  "$PKG_DIR/rtc_frame_cryptor.h"
  "$PKG_DIR/rtc_data_packet_cryptor.h"
  "$PKG_DIR/rtc_data_channel.h"
  "$PKG_DIR/rtc_rtp_sender.h"
  "$PKG_DIR/rtc_audio_device.h"
  "$PKG_DIR/rtc_media_track.h"
)

patched=0
skipped=0
missing=0

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "MISSING, skip: $f"
    missing=$((missing + 1))
    continue
  fi

  if grep -qE '#include[[:space:]]*[<"]c?stdint\.h?[>"]' "$f"; then
    echo "already patched, skip: $f"
    skipped=$((skipped + 1))
    continue
  fi

  tmp="$(mktemp)"
  awk '
    BEGIN { inserted = 0; saw_ifndef = 0 }
    {
      if (!inserted && saw_ifndef == 1 && $0 ~ /^#define /) {
        print $0
        print "#include <stdint.h>"
        inserted = 1
        saw_ifndef = 0
        next
      }
      if (!inserted && $0 ~ /^#ifndef /) {
        saw_ifndef = 1
        print $0
        next
      }
      if (!inserted && $0 ~ /^#include/) {
        print "#include <stdint.h>"
        inserted = 1
      }
      print $0
    }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
  echo "patched: $f"
  patched=$((patched + 1))
done

echo ""
echo "Summary: patched=$patched skipped(already-ok)=$skipped missing=$missing"
