#!/usr/bin/env python3
"""Reproduce v3 or build a single-variable init-path test from its exact payload."""
import argparse
import hashlib
import pathlib
import struct
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("baseline", type=pathlib.Path)
p.add_argument("output", type=pathlib.Path)
p.add_argument("--emmc-init", action="store_true",
               help="change only DTB bootargs to project PID 1; requires fdtput")
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
b = a.baseline.read_bytes()
assert hashlib.sha256(b).hexdigest() == "4241d9b535068bceeed59d73bd5e78d2d0a7a3d545f2c1b313617181c04e7241", "unexpected v3 baseline"
def padded(data):
    return data + b"\0" * (-len(data) % 4)
def hash_words(data):
    h = 2166136261
    for (w,) in struct.iter_unpack("<I", data):
        h = ((h ^ w) * 16777619) & 0xffffffff
    return h
with tempfile.TemporaryDirectory() as tmp:
    d = pathlib.Path(tmp)
    k, dt = b[0x418:0x740724], b[0x740724:]
    (d / "kernel.bin").write_bytes(k)
    (d / "board.dtb").write_bytes(dt)
    if a.emmc_init:
        subprocess.run(["fdtput", "-t", "s", str(d / "board.dtb"), "/chosen", "bootargs",
                        "console=ttyS0,115200 root=/dev/mmcblk2p1 rootfstype=ext4 rootwait rw init=/sbin/pb626-emmc-init"], check=True)
        dt = padded((d / "board.dtb").read_bytes())
        (d / "board.dtb").write_bytes(dt)
    (d / "payload-check.inc").write_text(f".equ KERNEL_HASH, 0x{hash_words(k):08x}\n.equ DTB_HASH, 0x{hash_words(dt):08x}\n")
    (d / "entry.S").write_bytes((root / "boot/pb626-native-entry-v3.S").read_bytes())
    subprocess.run(["clang", "--target=armv7a-none-eabi", "-c", "entry.S", "-o", "entry.o"], cwd=d, check=True)
    subprocess.run(["ld.lld", "-Ttext=0x40008000", "--oformat=binary", "entry.o", "-o", "payload.bin"], cwd=d, check=True)
    out = (d / "payload.bin").read_bytes()
    assert len(out) <= 0x800000
    assert out[0x418:0x740724] == k
    assert out[0x740724:] == dt
    if not a.emmc_init:
        assert out == b, "baseline reproduction failed"
    a.output.write_bytes(out)
    print(hashlib.sha256(out).hexdigest(), a.output)
