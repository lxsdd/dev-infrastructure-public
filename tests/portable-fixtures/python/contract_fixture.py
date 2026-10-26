"""Synthetic positive/negative byte-preservation and source contract oracle.

No filesystem writes or user data. Ensure Python assertions cannot be disabled.
"""
import sys

assert sys.flags.optimize == 0, "CI must execute Python assertions"
source = b"TRACK 01 AUDIO\r\n    TITLE \"Original\"\r\n    REM VENDOR \"keep\"\r\n"
def patch(data: bytes, before: bytes, after: bytes) -> bytes:
    if not after or b'"' in after or b"\n" in after or b"\r" in after:
        raise ValueError("unsafe bytes")
    if data.count(before) != 1:
        raise ValueError("ambiguous/stale")
    return data.replace(before, after, 1)
updated = patch(source, b"Original", b"New")
assert updated != source
assert updated.count(b"\r\n") == source.count(b"\r\n")
assert b'REM VENDOR "keep"' in updated
assert patch(updated, b"New", b"Original") == source
for old, new in ((b"absent", b"New"), (b"Original", b"x\ny"), (b"Original", b"")):
    try:
        patch(source, old, new)
    except ValueError:
        continue
    raise AssertionError("unsafe mutation accepted")
print("PASS: portable Python positive/negative source-only contract")
