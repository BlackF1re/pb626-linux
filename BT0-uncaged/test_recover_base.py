#!/usr/bin/env python3
"""Synthetic roundtrip exercises inverse patch mechanics, not a real SPL."""
import importlib.util
from pathlib import Path
import tempfile

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pb626_spl_build", here / "build.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

base = bytearray(24576)
base[4:12] = b"eGON.BT0"
b.put(base, 16, len(base))
b.put(base, 0xa4, 0xea000331)
for off, old, new in b.PATCHES:
    base[off:off+len(bytes.fromhex(old))] = bytes.fromhex(old)
b.checksum(base)
b.BASE = b.sha(base)
safe = bytearray(base)
for off, old, new in b.PATCHES:
    safe[off:off+len(bytes.fromhex(new))] = bytes.fromhex(new)
b.checksum(safe)
b.SAFE = b.sha(safe)
final = bytearray(safe)
b.put(final, 0xa4, 0xea0013d5)
final[0x5000:0x5458] = bytes([0x55]) * 0x458
b.checksum(final)
b.FINAL = b.sha(final)
with tempfile.TemporaryDirectory() as tmp:
    p = Path(tmp) / "uncaged.bin"
    p.write_bytes(final)
    assert b.recover_base(p) == base
    final[0x600] ^= 1
    b.checksum(final)
    p.write_bytes(final)
    try:
        b.recover_base(p)
    except SystemExit:
        pass
    else:
        raise AssertionError("Unknown input accepted")
print("SPL reverse patch synthetic roundtrip and rejection passed")
