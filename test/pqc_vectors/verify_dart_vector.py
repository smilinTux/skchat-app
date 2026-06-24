#!/usr/bin/env python3
"""Open a Dart-PqDmCodec-sealed blob with skcomms/pqdm.py (Dart → Python gate).

Reads `dart_sealed.json` (emitted by the Dart codec test) and proves the Python
daemon can OPEN a blob the Flutter app sealed — the second interop direction.

Run AFTER `flutter test test/services/pq_dm_codec_test.dart` has produced
dart_sealed.json:
    PYTHONPATH=<skcomms>/src python3 verify_dart_vector.py
"""
import base64
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKCOMMS_SRC = os.path.expanduser("~/clawd/skcapstone-repos/skcomms/src")
if SKCOMMS_SRC not in sys.path:
    sys.path.insert(0, SKCOMMS_SRC)

from skcomms import pqdm  # noqa: E402

def main():
    path = os.path.join(HERE, "dart_sealed.json")
    if not os.path.exists(path):
        print(f"SKIP: {path} not found (run the Dart codec test first)")
        return 0
    v = json.load(open(path))
    token = v["token"]
    assert token.startswith("pqdm1:"), f"missing pqdm1 prefix: {token[:16]}"
    rest = token[len("pqdm1:"):]
    suite, _, b64 = rest.partition(":")
    sealed = base64.b64decode(b64)
    priv = bytes.fromhex(v["recipient_private_hex"])
    clear = pqdm.open_sealed(
        sealed,
        priv,
        sender=v["sender"],
        recipient=v["recipient"],
        expected_suite=suite,
    )
    got = clear.decode("utf-8")
    assert got == v["plaintext"], f"mismatch: {got!r} != {v['plaintext']!r}"
    print("Dart → Python interop OK: pqdm.py opened the Dart-sealed blob")
    print(f"  plaintext: {got!r}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
