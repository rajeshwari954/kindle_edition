"""Seal a file with a passphrase so it can sit on the public Pages site without being readable.

Format: b"SVPK1" + 16-byte salt + ciphertext.
Key: k = sha256(salt + pass), then 1000 rounds of k = sha256(k + pass).
Cipher: SHA-256 in counter mode, keystream block n = sha256(k + n as 8-byte big-endian), XORed with the data.
The Kindle (dailyreads plugin) does the same in Lua with the passphrase saved in its settings.
"""
from __future__ import annotations

import hashlib
import os

MAGIC = b"SVPK1"


def _key(passphrase: str, salt: bytes) -> bytes:
    pw = passphrase.strip().encode("utf-8")
    k = hashlib.sha256(salt + pw).digest()
    for _ in range(1000):
        k = hashlib.sha256(k + pw).digest()
    return k


def _xor(data: bytes, k: bytes) -> bytes:
    out = bytearray(len(data))
    for n in range(0, (len(data) + 31) // 32):
        ks = hashlib.sha256(k + n.to_bytes(8, "big")).digest()
        chunk = data[n * 32:(n + 1) * 32]
        out[n * 32:n * 32 + len(chunk)] = bytes(a ^ b for a, b in zip(chunk, ks))
    return bytes(out)


def seal(data: bytes, passphrase: str) -> bytes:
    salt = os.urandom(16)
    return MAGIC + salt + _xor(data, _key(passphrase, salt))


def unseal(blob: bytes, passphrase: str) -> bytes:
    assert blob[:5] == MAGIC, "not a sealed file"
    salt = blob[5:21]
    return _xor(blob[21:], _key(passphrase, salt))


if __name__ == "__main__":
    msg = os.urandom(100_003)
    assert unseal(seal(msg, " test words "), "test words") == msg
    print("ok")
