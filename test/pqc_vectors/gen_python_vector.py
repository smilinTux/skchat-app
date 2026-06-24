#!/usr/bin/env python3
"""Generate a Python-pqdm-sealed cross-impl test vector for the Dart PqDmCodec.

Emits `python_sealed.json` — a blob sealed by skcomms/pqdm.py that the Dart side
must OPEN, proving Python→Dart interop. Also emits the recipient hybrid keypair
so the Dart test can decapsulate, and (separately) a Dart-sealed blob is opened
back here by `verify_dart_vector.py` to prove Dart→Python interop.

Run: PYTHONPATH=<skcomms>/src python3 gen_python_vector.py
"""
import base64
import json
import os
import sys

# Resolve skcomms src.
HERE = os.path.dirname(os.path.abspath(__file__))
SKCOMMS_SRC = os.path.expanduser("~/clawd/skcapstone-repos/skcomms/src")
if SKCOMMS_SRC not in sys.path:
    sys.path.insert(0, SKCOMMS_SRC)

from skcomms import pqkem, pqdm  # noqa: E402

SENDER = "lumina"
RECIPIENT = "chef"
PLAINTEXT = "hybrid post-quantum DM from the daemon 🔐 — pqdm.py → Dart"

def main():
    kp = pqkem.hybrid_keypair()
    bundle = pqdm.PrekeyBundle(
        suite=pqdm.HYBRID_SUITE,
        hybrid_public_hex=kp.public_key.hex(),
        key_id="py-vec-1",
    )
    sealed = pqdm.seal(
        PLAINTEXT.encode("utf-8"),
        bundle,
        sender=SENDER,
        recipient=RECIPIENT,
    )
    token = f"{pqdm.HYBRID_SUITE}:" + base64.b64encode(sealed).decode("ascii")
    # crypto.PQDM_SCHEME is "pqdm1:" — emit the full token as stored in content.
    full_token = "pqdm1:" + token

    out = {
        "suite": pqdm.HYBRID_SUITE,
        "sender": SENDER,
        "recipient": RECIPIENT,
        "plaintext": PLAINTEXT,
        "recipient_private_hex": kp.private_key.hex(),
        "recipient_public_hex": kp.public_key.hex(),
        "sealed_hex": sealed.hex(),
        "token": full_token,
        # AAD the Dart side must reconstruct (for cross-checking the bytes).
        "aad_b64": base64.b64encode(
            pqdm.downgrade_lock_aad(pqdm.HYBRID_SUITE, sender=SENDER, recipient=RECIPIENT)
        ).decode("ascii"),
    }
    path = os.path.join(HERE, "python_sealed.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"wrote {path}")
    # Self-check: open it back.
    re = pqdm.open_sealed(sealed, kp.private_key, sender=SENDER, recipient=RECIPIENT)
    assert re.decode("utf-8") == PLAINTEXT, "python self-roundtrip failed"
    print("python self-roundtrip OK")

if __name__ == "__main__":
    main()
