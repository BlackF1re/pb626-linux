#!/usr/bin/env python3
"""Reproduce the hardware-validated SPL. Never touches block devices."""
import argparse, hashlib, struct, subprocess, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
BASE = '7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f'
SAFE = '42a557fc000d09dd8d5c6d24b8914dd0ca1af42cbf121ff4a034de5b3d2850ed'
FINAL = '1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6'
def sha(b): return hashlib.sha256(b).hexdigest()
def check(ok, msg):
    if not ok: raise SystemExit(msg)
def word(b, off): return struct.unpack_from('<I', b, off)[0]
def put(b, off, value): struct.pack_into('<I', b, off, value)
def checksum(b):
    put(b, 12, 0x5f0a6c39)
    put(b, 12, sum(struct.unpack('<%dI' % (len(b)//4), b)) & 0xffffffff)
def verify(b):
    check(len(b) == 24576 and b[4:12] == b'eGON.BT0' and word(b,16)==len(b), 'Invalid SPL header')
    c=bytearray(b); checksum(c); check(c==b, 'Invalid eGON checksum')
def build(source):
    original=source.read_bytes(); check(sha(original)==BASE, 'Unexpected base SPL'); verify(original)
    b=bytearray(original)
    # MMC2 source, forced MMC2 boot-device function, 4096 sectors/request, 25 MHz.
    for off, old, new in [(0x28,'00','02'),(0x174,'08b50822','02207047'),(0x3d54,'4ff6ff73','41f20003'),(0x3e34,'00751903','40787d01')]:
        old=bytes.fromhex(old); new=bytes.fromhex(new)
        check(b[off:off+len(old)]==old, 'Patch preimage mismatch')
        b[off:off+len(new)]=new
    checksum(b); verify(b); check(sha(b)==SAFE, 'MMC2-safe mismatch')
    with tempfile.TemporaryDirectory() as tmp:
        t=Path(tmp)
        subprocess.run(['clang','--target=armv7a-none-eabi','-c',str(HERE/'early-menu.S'),'-o',str(t/'menu.o')],check=True)
        subprocess.run(['ld.lld','-Ttext=0x5000','-e','_start',str(t/'menu.o'),'-o',str(t/'menu.elf')],check=True)
        subprocess.run(['llvm-objcopy','-O','binary','-j','.text',str(t/'menu.elf'),str(t/'menu.raw')],check=True)
        hook=(t/'menu.raw').read_bytes()
    check(len(hook)==0x458 and not any(b[0x5000:0x5458]), 'Unexpected hook or nonempty padding')
    check(word(b,0xa4)==0xea000331, 'Unexpected original entry branch')
    put(b,0xa4,0xea000000|((0x5000-0xa4-8)//4)); b[0x5000:0x5458]=hook
    checksum(b); verify(b); check(sha(b)==FINAL, 'Output differs from hardware-validated SPL')
    return b
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('base',type=Path); p.add_argument('output',type=Path); a=p.parse_args()
    result=build(a.base); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_bytes(result); print(sha(result),a.output)
