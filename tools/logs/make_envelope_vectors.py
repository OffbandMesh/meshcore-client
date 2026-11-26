"""Reference vectors for the Offband log envelope (#1208).

Writes test/fixtures/log_envelope_vectors.json. The Dart encoder must
reproduce each envelope byte for byte, and offband_logs.py must open it. This
uses Python's `cryptography` library, so it is independent of the app.

    python tools/logs/make_envelope_vectors.py test/fixtures/log_envelope_vectors.json
"""
import hashlib
import json
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

INFO = b"offband-log-v1"


def raw_public(key):
    return key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def raw_private(key):
    return key.private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )


def seal(plaintext, recipient_public, ephemeral, nonce):
    eph_public = raw_public(ephemeral)
    shared = ephemeral.exchange(X25519PublicKey.from_public_bytes(recipient_public))
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=eph_public + recipient_public,
        info=INFO,
    ).derive(shared)
    key_id = hashlib.sha256(recipient_public).digest()[:4]
    header = b"OBLG" + bytes([1]) + key_id + eph_public + nonce
    return header + AESGCM(key).encrypt(nonce, plaintext, header)


CASES = [
    (bytes(range(1, 33)), bytes(range(101, 133)), bytes(range(12)), b"offband log package"),
    (bytes([7] * 32), bytes([9] * 32), bytes([0xFF] * 12), b""),
    (bytes(range(200, 232)), bytes(range(50, 82)), bytes(range(40, 52)), bytes(range(256)) * 4),
]


def main(out_path):
    vectors = []
    for recipient_seed, eph_seed, nonce, plaintext in CASES:
        recipient = X25519PrivateKey.from_private_bytes(recipient_seed)
        ephemeral = X25519PrivateKey.from_private_bytes(eph_seed)
        vectors.append(
            {
                "recipientPrivate": raw_private(recipient).hex(),
                "recipientPublic": raw_public(recipient).hex(),
                "ephemeralPrivate": raw_private(ephemeral).hex(),
                "nonce": nonce.hex(),
                "plaintext": plaintext.hex(),
                "envelope": seal(plaintext, raw_public(recipient), ephemeral, nonce).hex(),
            }
        )
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"info": INFO.decode(), "vectors": vectors}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv[1])
