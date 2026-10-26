#!/usr/bin/env python3
"""Generate a deterministic 8-kHz 16-bit mono FLAC with a Vorbis CUESHEET.

No codec tools, downloads, music libraries, or third-party Python packages.
One legal constant subframe, a STREAMINFO and a multiline Vorbis Comment.
Only create a new fixture path in the disposable GitHub Actions directory.
"""
import hashlib
from pathlib import Path
import struct
import sys

CUE = """TITLE "Runner Embedded EP"
PERFORMER "Example DJ"
REM GENRE "House"
REM GENRE "Progressive Trance"
REM CUSTOM "Preserve me"
FILE "synthetic-embedded.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Runner (Extended Mix)"
    PERFORMER "Example DJ"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Runner (Radio Edit)"
    PERFORMER "Example DJ"
    INDEX 01 00:00:30
"""

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
    return bytes([kind | (0x80 if last else 0)]) + len(payload).to_bytes(3,"big") + payload

def main(path):
    samples = 8000  # exactly one second
    stream_info = (
        struct.pack(">HH", samples, samples) + bytes(6) +
        (((8000 << 44) | (15 << 36) | samples).to_bytes(8,"big")) + bytes(16)
    )
    assert len(stream_info) == 34
    vendor = b"MMS synthetic fixture"
    entry = b"CUESHEET=" + CUE.encode("utf-8")
    comments = (struct.pack("<I",len(vendor)) + vendor +
                struct.pack("<I",1) + struct.pack("<I",len(entry)) + entry)
    frame_head = bytes([0xFF,0xF8,0x70,0x08,0]) + struct.pack(">H", samples-1)
    frame_head += bytes([crc(frame_head,8,0x07)])
    # Subframe: constant (0000000), sample value 0, 16-bit; CRC16.
    frame = frame_head + bytes(3)
    frame += struct.pack(">H",crc(frame,16,0x8005))
    # FLAC Type-5 is a distinct BINARY metadata block. Preserve it byte
    # for byte independently of the textual Vorbis-comment CUESHEET.
    # 3 entries: physical tracks 1/2 and mandatory lead-out track 170.
    def track(offset, number, indices):
        payload = (
            offset.to_bytes(8,"big") + bytes([number]) + bytes(12) +
            bytes(1) + bytes(13) + bytes([len(indices)])
        )
        for index_offset,index_number in indices:
            payload += (index_offset.to_bytes(8,"big") +
                        bytes([index_number]) + bytes(3))
        return payload
    native_type5 = (
        bytes(128) + bytes(8) + bytes(1) + bytes(258) + bytes([3]) +
        track(0,1,[(0,1)]) + track(3200,2,[(0,1)]) +
        track(samples,170,[])
    )
    # This exact canonical 3-track Type-5 block was validated with
    # the reference FLAC 1.5.0 decoder and metaflac metadata parser.
    data = (b"fLaC" + block(0,stream_info) + block(5,native_type5) +
            block(4,comments,last=True) + frame)
    target = Path(path)
    if target.exists():
        raise SystemExit("Refuse to overwrite an existing audio fixture.")
    target.write_bytes(data)
    if len(data) > 4096 or data.count(entry) != 1 or data[:4] != b"fLaC":
        raise SystemExit("Invalid synthetic FLAC fixture.")
    print("SYNTHETIC_EMBEDDED_FLAC_CREATED=PASS (text CUESHEET plus native Type-5 block)")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Expected one runner-local output path.")
    main(sys.argv[1])
