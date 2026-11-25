#!/usr/bin/env python3
"""Build the SPL's legacy uImage from zImage + native DTB; no device access."""
import argparse, hashlib, struct, subprocess, tempfile, zlib
from pathlib import Path
HERE=Path(__file__).resolve().parent

def fnv_words(data):
    h=2166136261
    for (w,) in struct.iter_unpack('<I',data): h=((h^w)*16777619)&0xffffffff
    return h

def pack(kernel, dtb):
    kernel=kernel+bytes(-len(kernel)%4); dtb=dtb+bytes(-len(dtb)%4)
    if len(kernel)<0x28 or struct.unpack_from('<I',kernel,0x24)[0]!=0x016f2818 or dtb[:4]!=bytes.fromhex('d00dfeed'):
        raise SystemExit('Expected ARM zImage and native DTB')
    if len(kernel)>=0x1000000 or len(dtb)>=0x1000000: raise SystemExit('Relocation window exceeded')
    with tempfile.TemporaryDirectory() as tmp:
        d=Path(tmp)
        (d/'kernel.bin').write_bytes(kernel); (d/'board.dtb').write_bytes(dtb)
        (d/'payload-check.inc').write_text(f'.equ KERNEL_HASH, 0x{fnv_words(kernel):08x}\n.equ DTB_HASH, 0x{fnv_words(dtb):08x}\n')
        subprocess.run(['clang','--target=armv7a-none-eabi','-c',str(HERE/'kernel-entry.S'),'-o','entry.o'],cwd=d,check=True)
        subprocess.run(['ld.lld','-Ttext=0x40008000','--oformat=binary','entry.o','-o','payload.bin'],cwd=d,check=True)
        payload=(d/'payload.bin').read_bytes()
    if not payload.endswith(kernel+dtb) or len(payload)>0x800000: raise SystemExit('Invalid payload')
    head=bytearray(struct.pack('>7I4B32s',0x27051956,0,0,len(payload),0x40008000,0x40008000,zlib.crc32(payload),17,2,5,0,b'PB626 Linux native'))
    struct.pack_into('>I',head,4,zlib.crc32(head)); raw=bytes(head)+payload
    return raw+bytes(-len(raw)%512)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('kernel',type=Path);p.add_argument('dtb',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    raw=pack(a.kernel.read_bytes(),a.dtb.read_bytes());a.output.write_bytes(raw);print(hashlib.sha256(raw).hexdigest(),a.output,len(raw),'bytes')
