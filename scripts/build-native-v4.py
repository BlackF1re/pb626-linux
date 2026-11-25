#!/usr/bin/env python3
"""Build two independent PB626 native boot experiments from exact v3 ZIP.
Requires clang and ld.lld. Does not write to hardware or alter DTB/rootfs.
"""
import argparse, hashlib, pathlib, struct, subprocess, tempfile, zipfile

def sha(b): return hashlib.sha256(b).hexdigest()
def branch(addr, dest):
    delta = dest - addr - 8
    assert delta % 4 == 0 and -(1<<25) <= delta < (1<<25)
    return 0xea000000 | ((delta >> 2) & 0xffffff)

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('archive',type=pathlib.Path)
p.add_argument('out',type=pathlib.Path)
a=p.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(a.archive) as z:
    b=z.read('pb626v3.bin'); source=z.read('pb626-native-entry-v3.S').decode(); inc=z.read('payload-check.inc')
assert sha(b)=='4241d9b535068bceeed59d73bd5e78d2d0a7a3d545f2c1b313617181c04e7241'
assert sha(source.encode())=='45f50f9f854993dce18cf34473b40e426fbde7fbf0f417d3d020f1d05e1ed6c5'
k,dt=b[0x418:0x740724],b[0x740724:]
# addr, original instruction, replay (absolute PC-relative values), pulse count
hooks=[(0x4600003c,0xe10f9000,'mrs r9, apsr',4),
       (0x460000d8,0xe1a0000f,'ldr r0, =0x460000e0',5),
       (0x460000f4,0xe28f0e21,'ldr r0, =0x4600030c',6),
       (0x46000284,0xe1a00004,'mov r0, r4',7),
       (0x46000298,0xe28f1078,'ldr r1, =0x46000318',8),
       (0x46000980,0xe3a00000,'mov r0, #0',9)]
for addr,word,_,_ in hooks: assert struct.unpack_from('<I',k,addr-0x46000000)[0]==word
# Reuse v3's GPIO pulse implementation, no TWI transactions in either variant.
base=source[:source.index('twi:\n')]+ 'twi:\n    bx r10\n.ltorg\n.balign 4\n'+source[source.index('.include "payload-check.inc"'):]
start=base.index('    ldr r0, =kernel_probe\n'); end=base.index('    mov r0, #0\n    mcr p15',start)
# Use original v3 PE8 GPIO routine in a self-contained relocated blob.
led=source[source.index('led_begin:\n'):source.index('twi:\n')]
led=led.replace("led_begin", "relocated_begin").replace("led_loop", "relocated_loop")
for diag in (False,True):
    name='pb626-v4-stages' if diag else 'pb626-v4-clean'
    install=''
    blob=''
    if diag:
        install='    ldr r0, =kernel_probe\n    ldr r1, =kernel_probe_end\n    ldr r2, =0x45fff000\n    bl copy_words\n'
        blob='    .balign 128\nkernel_probe:\n'
        for i,(addr,word,replay,n) in enumerate(hooks):
            dest=0x45fff000+i*128
            install+=f'    ldr r0, =0x{addr:08x}\n    ldr r1, =0x{branch(addr,dest):08x}\n    str r1, [r0]\n'
            blob+=f'''hook_{n}:
    push {{r0-r12, lr}}
    mrs r0, cpsr
    push {{r0, r1}}
    mov r7, #{n}
    bl relocated_led
    pop {{r0, r1}}
    msr cpsr_f, r0
    pop {{r0-r12, lr}}
    {replay}
    ldr pc, =0x{addr+4:08x}
    .ltorg
    .balign 128
'''
        install+='    dsb sy\n'
        blob+='relocated_led:\n'+led+'    bx lr\n.ltorg\n.balign 4\nkernel_probe_end:\n'
    else:
        install='    mov r8, #0x85\n    bl trace_mark\n'
    s=base[:start]+install+base[end:]
    s=s.replace('.include "payload-check.inc"',blob+'.include "payload-check.inc"')
    # Separate successive pulse groups, even when adjacent hooks execute immediately.
    s=s.replace("    str r2, [r0]\nled_loop:", "    str r2, [r0]\n    mov r2, #0x04000000\n9:  subs r2, r2, #1\n    bne 9b\nled_loop:")
    s=s.replace("    str r2, [r0]\nrelocated_loop:", "    str r2, [r0]\n    mov r2, #0x04000000\n9:  subs r2, r2, #1\n    bne 9b\nrelocated_loop:")
    with tempfile.TemporaryDirectory() as tmp:
        d=pathlib.Path(tmp)
        for f,data in [('entry.S',s.encode()),('kernel.bin',k),('board.dtb',dt),('payload-check.inc',inc)]: (d/f).write_bytes(data)
        subprocess.run(['clang','--target=armv7a-none-eabi','-c','entry.S','-o','entry.o'],cwd=d,check=True)
        subprocess.run(['ld.lld','-Ttext=0x40008000','--oformat=binary','entry.o','-o','payload.bin'],cwd=d,check=True)
        subprocess.run(['ld.lld','-Ttext=0x40008000','entry.o','-o','entry.elf'],cwd=d,check=True)
        out=(d/'payload.bin').read_bytes()
        assert len(out)<=0x800000 and out.endswith(k+dt)
        # Optional ELF for independent symbol/disassembly inspection.
        (a.out/(name+'.elf')).write_bytes((d/'entry.elf').read_bytes())
        (a.out/(name+'.S')).write_text(s)
        (a.out/(name+'.bin')).write_bytes(out)
        print(name,len(out),sha(out))
