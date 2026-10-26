#!/usr/bin/env python3
"""Pure stdlib, disposable 1-second FLAC with original DJ collaboration tags.

Creates a new fixture ONLY in GitHub RUNNER_TEMP. No downloaded/user music,
no third-party library, and no CUE or audio rewrite path is exercised.
"""
from pathlib import Path
import struct
import sys

def crc(data, bits, polynomial):
    value = 0
    mask = (1 << bits) - 1
    for byte in data:
        value ^= byte << (bits - 8)
        for _ in range(8):
            value = (((value << 1) ^ polynomial) & mask
                     if value & (1 << (bits - 1)) else (value << 1) & mask)
    return value

def block(kind, payload, last=False):
    assert len(payload) < 1 << 24
    return bytes([kind | (0x80 if last else 0)]) + len(payload).to_bytes(3, "big") + payload

def main(path):
    samples = 8000
    stream = (struct.pack(">HH", samples, samples) + bytes(6) +
              (((8000 << 44) | (15 << 36) | samples).to_bytes(8, "big")) +
              bytes(16))
    assert len(stream) == 34
    vendor = b"MMS read-only synthetic Discogs QA"
    tags = (b"TITLE=1000 Years",
            b"ARTIST=Kyau & Albert X Maywave",
            b"VERSION=DJ Version")
    comments = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(tags))
    for tag in tags:
        comments += struct.pack("<I", len(tag)) + tag
    fh = bytes([0xFF, 0xF8, 0x70, 0x08, 0]) + struct.pack(">H", samples - 1)
    fh += bytes([crc(fh, 8, 0x07)])
    frame = fh + bytes(3)
    frame += struct.pack(">H", crc(frame, 16, 0x8005))
    data = b"fLaC" + block(0, stream) + block(4, comments, last=True) + frame
    target = Path(path)
    if target.exists():
        raise SystemExit("Refuse to overwrite an existing synthetic audio fixture")
    target.write_bytes(data)
    if len(data) > 1024 or data[:4] != b"fLaC" or any(data.count(t) != 1 for t in tags):
        raise SystemExit("Synthetic tagged FLAC self-check failed")
    print("SYNTHETIC_DISCOGS_FULL_ARTIST_FLAC=PASS (tagged, no writes)")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("One explicit new runner-temp FLAC path required")
    main(sys.argv[1])
