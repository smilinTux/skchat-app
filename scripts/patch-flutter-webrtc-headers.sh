#!/usr/bin/env bash
# Idempotent fix for flutter_webrtc 1.5.2 bundled libwebrtc headers missing
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
# Usage:
#   bash patch-flutter-webrtc-headers.sh
# Run this on the machine that owns the pub cache (eg 192.168.0.41), since
# the flutter plugin symlinks its ephemeral headers back into the pub cache.

set -euo pipefail

PUB_ROOT="${PUB_ROOT:-$HOME/.pub-cache/hosted/pub.dev}"
PKG_DIR="$PUB_ROOT/flutter_webrtc-1.5.2/third_party/libwebrtc/include"

if [ ! -d "$PKG_DIR" ]; then
  echo "flutter_webrtc include dir not found at: $PKG_DIR" >&2
  echo "Set PUB_ROOT to override the pub cache location." >&2
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
