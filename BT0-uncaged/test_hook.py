#!/usr/bin/env python3
"""Limited ARM interpreter for the actual early-menu hook, with mocked LRADC.
Not a SoC emulator. Timeout shortened only in the model.
Unknown instructions and out-of-scope memory accesses fail the test.
"""
from pathlib import Path
import struct, sys, hashlib
from itertools import product
P=Path(__file__).resolve().parent
# PR CI can test the exact assembled hook without the unavailable base SPL.
HOOK=0x5000; SAVE=0xd70; REPORT=0x5400; POLL_INIT=0x5060; ENTRY=0
if len(sys.argv)==3 and sys.argv[1]=='--hook-only':
    hook=Path(sys.argv[2]).read_bytes()
    assert len(hook)==0x458 and hashlib.sha256(hook).hexdigest()=='67c152443fc89a48b65b535c3e8bdb21752b8fe3a96ab106bf948dacab2a96da'
    fixture=bytearray(0x6000)
    struct.pack_into('<I',fixture,0xa4,0xea0013d5)
    fixture[0x5000:0x5458]=hook
    BIN=bytes(fixture)
    ENTRY=0xa4
elif len(sys.argv)==4 and sys.argv[1]=='--candidate':
    BIN=Path(sys.argv[2]).read_bytes()
    assert len(BIN)==24576 and BIN[4:12]==b'eGON.BT0'
    want,size=struct.unpack_from('<II',BIN,12)
    assert size==len(BIN)
    check=bytearray(BIN); struct.pack_into('<I',check,12,0x5f0a6c39)
    assert sum(struct.unpack('<6144I',check))&0xffffffff==want
    syms={l.split()[-1]:int(l.split()[0],16) for l in Path(sys.argv[3]).read_text().splitlines() if len(l.split())==3}
    HOOK=syms['pb626_menu_hook']; SAVE=syms['save_boot_params']; REPORT=syms['pb626_report']
    assert 0<HOOK<REPORT<0x6000 and 0<SAVE<0x6000
    opcode=bytes.fromhex('0287a0e3')
    assert BIN[HOOK:REPORT].count(opcode)==1
    POLL_INIT=HOOK+BIN[HOOK:REPORT].index(opcode)
else:
    BIN=Path(sys.argv[1] if len(sys.argv)>1 else P/'BT0-uncaged.bin').read_bytes()
    assert hashlib.sha256(BIN).hexdigest()=='1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6'
assert struct.unpack_from('<I',BIN,POLL_INIT)[0]==0xe3a08702
ADC=0x01c22800; MASK=0xffffffff

def run(samples, *, fel=False, high=True, lr=None, events=0):
    mem=bytearray(BIN); r=[0x12340000+i for i in range(16)]
    r[13]=0x5df8; r[14]=lr if lr is not None else (0xa2c0 if fel else 0xffff1234)
    original=r.copy(); r[15]=ENTRY
    if fel:mem[8:12]=b'.FEL'
    ctrl,intc=0x0100016a,0x12; old=(ctrl,intc); cpsr=0x60000153; old_cpsr=cpsr
    sctlr=0x00c52078 if high else 0x00c50078
    n=z=c=v=0; i=0; converted=False; executed=0
    def get(x):return (r[15]+8)&MASK if x==15 else r[x]
    def rd(a):
        if a==ADC:return ctrl
        if a==ADC+4:return intc
        if a==ADC+8:return (int(i<len(samples)) | events) if converted else 0
        if a==ADC+12:
            assert converted and i<len(samples);return samples[i]
        assert 0<=a<=len(mem)-4,hex(a)
        return struct.unpack_from('<I',mem,a)[0]
    def wr(a,val):
        nonlocal ctrl,intc,i,converted
        val&=MASK
        if a==ADC:ctrl=val;converted=val==0x02002141;return
        if a==ADC+4:intc=val;return
        if a==ADC+8:
            if converted and val==1:i+=1
            return
        assert REPORT<=a<REPORT+88 and a%4==0,hex(a)
        struct.pack_into('<I',mem,a,val)
    def flags(val,a=None,b=None):
        nonlocal n,z,c,v
        x=val&MASK;n=x>>31;z=int(x==0)
        if a is not None:c=int(a>=b);v=int(bool((a^b)&(a^x)&0x80000000))
    def cond(k):
        return [z,not z,c,not c,n,not n,v,not v,c and not z,not c or z,n==v,n!=v,not z and n==v,z or n!=v,True,True][k]
    while r[15] not in (SAVE,0xffff0020,0x20,original[14]):
        pc=r[15]; assert pc in (0,0x60,0xa4) or HOOK<=pc<REPORT,hex(pc)
        w=rd(pc); executed+=1; assert executed<2000
        if not cond(w>>28):r[15]+=4;continue
        nxt=pc+4
        if w==0xf10c00c0:cpsr|=0xc0
        elif w==0xf57ff04f:pass
        elif w==0xe10f9000:r[9]=cpsr
        elif w==0xe121f002:cpsr=(cpsr&~0xff)|(r[2]&0xff)
        elif w==0xee111f10:r[1]=sctlr
        elif w&0x0ffffff0==0x012fff10:nxt=get(w&15)
        elif w&0x0e000000==0x0a000000:
            off=w&0xffffff;off-=0x1000000 if off&0x800000 else 0;nxt=pc+8+off*4
        elif w&0x0ff00000 in (0x03000000,0x03400000):
            d=(w>>12)&15;imm=((w>>4)&0xf000)|(w&0xfff)
            r[d]=((r[d]&0xffff)|(imm<<16)) if w&0x00400000 else imm
        elif w&0x0e000000==0x08000000:
            assert (w&0x01a00000)==0x00800000
            a=get((w>>16)&15)
            for j in range(16):
                if w&(1<<j):
                    if w&0x00100000:r[j]=rd(a)
                    else:wr(a,get(j))
                    a+=4
        elif w&0x0c000000==0x04000000:
            assert (w&0x01e00000)==0x01800000
            b=get((w>>16)&15);d=(w>>12)&15
            if w&0x02000000:
                assert w&0x70==0
                off=(get(w&15)<<((w>>7)&31))&MASK
            else:off=w&0xfff
            if w&0x00100000:r[d]=rd((b+off)&MASK)
            else:wr((b+off)&MASK,get(d))
        elif w&0x0c000000==0:
            op=(w>>21)&15;a=get((w>>16)&15);d=(w>>12)&15
            if w&0x02000000:
                b=w&255;rot=((w>>8)&15)*2;b=((b>>rot)|(b<<(32-rot)))&MASK
            else:
                assert w&0xff0==0;b=get(w&15)
            if op==0:val=a&b
            elif op==2:val=a-b
            elif op==4:val=a+b
            elif op==8:val=a&b
            elif op==10:val=a-b
            elif op==13:val=b
            else:raise AssertionError(hex(w))
            if op not in (8,10):r[d]=val&MASK
            if w&0x00100000 or op in (8,10):flags(val,a,b) if op in (2,10) else flags(val)
            if pc==POLL_INIT:r[8]=3 # model shortcut, real image has 0x80000
        else:raise AssertionError(hex(w))
        r[15]=nxt&MASK
    assert (ctrl,intc)==old and r[4:10]==original[4:10] and r[13]==original[13] and (cpsr&255)==(old_cpsr&255)
    rep=struct.unpack_from('<10I',mem,REPORT)
    assert rep[0]==0x36324250 and rep[8:10]==old
    if r[15]==SAVE or (fel and r[15]==original[14]):assert r[14]==original[14]
    return r[15],rep[1],rep[2],rep[3:7]

def check(samples,expect,**kw):
    dest,reason,n,values=run(samples,**kw)
    assert (dest,reason)==expect,(samples,kw,hex(dest),reason,expect)
    assert n==max(0,min(4,len(samples)-1))
    assert values[:n]==tuple(x&63 for x in samples[1:1+n])

count=0
for fel,high in product([False,True],repeat=2):
    recover=0xa2c0 if fel else 0xffff0020 if high else 0x20
    for values in product([0,6,13,47,48,63],repeat=4):
        normal=min(values)>=48
        check([0,*values],(SAVE,1) if normal else (recover,2),fel=fel,high=high);count+=1
    for n in range(5):
        check([63]*n,(recover,3) if n else (SAVE,1),fel=fel,high=high);count+=1
    for event in (2,4,8,16,30):
        check([],(recover,3),fel=fel,high=high,events=event);count+=1
        check([63]*5,(recover,2),fel=fel,high=high,events=event);count+=1
    check([41]*5,(recover,2),fel=fel,high=high);count+=1
check([63,13,13,13,13],(0xffff0020,2),fel=True,lr=0x9000);count+=1
print(f'PASS: {count} mocked ARM execution cases; actual binary; entry, all combinations, timeout, restore and recovery targets.')
