#!/usr/bin/env python3
"""Full-dump operations over USB NCM, compatible with the existing dump files."""
import argparse
import gzip
import hashlib
import shutil
import time
import os
from pathlib import Path
import re
import importlib
d = importlib.import_module("install-direct")
CHUNK = d.CHUNK

def info(r,sd):
    rows = r.lines("dump-info","sd" if sd else "emmc")
    cid = [x[4:] for x in rows if re.fullmatch("CID=[0-9a-f]{32}",x)]
    d.require(len(cid)==1,"Invalid CID")
    if sd:
        sectors = [int(x[8:]) for x in rows if re.fullmatch("SECTORS=[0-9]+",x)]
        d.require(len(sectors)==1 and 0<sectors[0]<=2147483648,"Invalid SD geometry")
        return cid[0],sectors[0],None
    ext = [bytes.fromhex(x[8:]) for x in rows if re.fullmatch("EXT_CSD=[0-9a-fA-F]{1024}",x)]
    d.require(len(ext)==1,"Invalid EXT_CSD")
    return cid[0],15269888,ext[0]

def regions(sd,sectors):
    if sd:
        return [("sd","pb626-sd.img",sectors*512)]
    return [(x,"pb626-emmc-"+x+".img",sectors*512 if x=="user" else CHUNK)
            for x in ("user","boot0","boot1")]

def read_block(r,cid,sectors,region,i,length):
    raw = r.request("dump",cid,sectors,"backup-read-packed",region,i)
    match = re.match(rb"\nPB626_DATA ([0-9]+) ([0-9a-f]{64}) (raw|gzip|zero)\n",raw)
    d.require(match is not None,"Invalid backup frame")
    n = int(match[1])
    d.require(0<=n<=CHUNK and raw[match.end()+n:]==b"\nPB626_DATA_END\n","Invalid frame length")
    payload = raw[match.end():match.end()+n]
    data = gzip.decompress(payload) if match[3]==b"gzip" else (
        bytes(length) if match[3]==b"zero" else payload)
    d.require(len(data)==length and d.sha(data)==match[2].decode(),"Backup chunk hash mismatch")
    return data

def write_block(r,cid,sectors,region,i,data):
    packed=gzip.compress(data,compresslevel=1)
    fmt,payload=("gzip",packed) if len(packed)<len(data) else ("raw",data)
    rows=r.lines("dump",cid,sectors,"write",region,i,fmt,len(payload),d.sha(data),payload=payload)
    d.require(rows==[f"PB626_WRITTEN {i} {d.sha(data)}"],"Missing verified restore acknowledgement")

def digest(r,cid,sectors,region,op):
    rows=r.lines("dump",cid,sectors,op,region,timeout=3600)
    hashes=[x[7:] for x in rows if re.fullmatch("SHA256 [0-9a-f]{64}",x)]
    d.require(len(hashes)==1,"Missing full-device hash")
    return hashes[0]

def scan(r,cid,sectors,region,count):
    rows=r.lines("dump",cid,sectors,"scan",region,timeout=3600,max_response=32*1024*1024)
    actual={}
    for line in rows:
        m=re.fullmatch("BLOCK ([0-9]+) ([0-9a-f]{64})",line)
        if m:
            index=int(m[1]); d.require(index not in actual,"Duplicate scan entry")
            actual[index]=m[2]
    d.require(set(actual)==set(range(count)),"Incomplete disk scan")
    return actual


def backup_region(r,cid,sectors,region,size,partial,finished):
    d.require(not (partial.exists() and finished.exists()),"Ambiguous backup files")
    count=(size+CHUNK-1)//CHUNK
    local=finished if finished.exists() else partial
    if local.exists():
        d.require(local.is_file() and local.stat().st_size<=size,"Invalid partial backup extent")
        print("Checking saved chunks against current eMMC:",region,flush=True)
        actual=scan(r,cid,sectors,region,count)
        if local==finished:
            # A completed region may be reused only if the live medium
            # still matches the complete local image.
            if local.stat().st_size==size and d.filehash(local)==digest(r,cid,sectors,region,"backup-hash"):
                print("Already verified:",region,flush=True)
                return
            local.rename(partial)
        mode="r+b"
    else:
        actual={}
        mode="x+b"
    h=hashlib.sha256()
    started=time.monotonic()
    reused=0
    with partial.open(mode) as f:
        for i,offset in enumerate(range(0,size,CHUNK)):
            length=min(CHUNK,size-offset)
            f.seek(offset)
            data=f.read(length)
            if len(data)==length and actual.get(i)==d.sha(data):
                reused+=1
            else:
                data=read_block(r,cid,sectors,region,i,length)
                f.seek(offset)
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            h.update(data)
            d.progress(region,i+1,count,started)
        f.truncate(size); f.flush(); os.fsync(f.fileno())
    print(f"{region}: {reused} saved chunks reused. Verifying full region...",flush=True)
    d.require(h.hexdigest()==digest(r,cid,sectors,region,"backup-hash"),"Full backup hash mismatch; keep partial and resume")
    d.require(d.filehash(partial)==h.hexdigest(),"Local backup readback mismatch")
    partial.rename(finished)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action",choices=("backup","restore","preflight"))
    ap.add_argument("directory",type=Path)
    ap.add_argument("--sd",action="store_true")
    ap.add_argument("--windows",action="store_true",help="Native Windows TCP")
    ap.add_argument("--journal",type=Path,help="Local write-state record")
    args=ap.parse_args()
    d.journal(args.journal,'preflight')
    r=d.EthernetRecovery(windows=args.windows)
    if args.windows:
        d.check_windows_recovery(r,Path(__file__).resolve().parent)
    cid,sectors,ext=info(r,args.sd)
    images=regions(args.sd,sectors)
    path=args.directory
    cidname="pb626-sd-cid.txt" if args.sd else "pb626-emmc-cid.txt"
    extname="pb626-emmc-ext-csd.bin"
    r.test_transport()
    if args.action=="backup":
        path.parent.mkdir(parents=True,exist_ok=True)
        required=sum(size for _,_,size in images)
        names=[cidname]+([extname] if ext is not None else [])
        if path.exists():
            d.require(path.is_dir() and not (path/"SHA256SUMS").exists(),"Not an incomplete backup directory")
            d.require((path/cidname).read_text().strip()==cid,"Partial backup belongs to a different card")
            if ext is not None:
                old=(path/extname).read_bytes()
                d.require(len(old)==512,"Invalid partial EXT_CSD")
                for start,end in ((143,156),(179,180),(212,216),(226,227)):
                    d.require(old[start:end]==ext[start:end],"Partial backup geometry differs")
            for _,name,size in images:
                candidates=[p for p in (path/name,path/(name+".partial")) if p.exists()]
                d.require(len(candidates)<=1,"Ambiguous partial backup")
                if candidates:
                    d.require(candidates[0].is_file() and candidates[0].stat().st_size<=size,"Invalid partial extent")
                    required-=candidates[0].stat().st_size
        else:
            path.mkdir(exist_ok=False)
            (path/cidname).write_text(cid+"\n")
            if ext is not None:
                (path/extname).write_bytes(ext)
        d.require(shutil.disk_usage(path).free>=required+16*1024*1024,
                  f"Not enough disk space; remaining backup needs {required/1024**3:.2f} GiB plus metadata")
        print("Backup directory:",path,flush=True)
        for region,name,size in images:
            backup_region(r,cid,sectors,region,size,path/(name+".partial"),path/name)
            names.append(name)
        d.require(info(r,args.sd)[0]==cid,"CID changed")
        # Final manifest is the completion marker; never publish one for a
        # partial dump. Verify all device regions again before publishing it.
        for region,name,size in images:
            d.require(d.filehash(path/name)==digest(r,cid,sectors,region,"backup-hash"),
                      "Device changed during backup; resume to reconcile")
        pending=path/"SHA256SUMS.partial"
        with pending.open("w",encoding="ascii") as f:
            f.write("".join(d.filehash(path/n)+"  "+n+"\n" for n in names))
            f.flush(); os.fsync(f.fileno())
        pending.replace(path/"SHA256SUMS")
        print("Verified full dump:",path,flush=True)
        return
    sums=d.manifest(path/"SHA256SUMS")
    names=[cidname]+([extname] if ext is not None else [])+[n for _,n,_ in images]
    for n in names:
        d.require(d.filehash(path/n)==sums.get(n),"Invalid dump file "+n)
    d.require((path/cidname).read_text().strip()==cid,"Different card CID")
    if ext is not None:
        old=(path/extname).read_bytes()
        d.require(len(old)==512,"Invalid EXT_CSD snapshot")
        # Do not program EXT_CSD; compare layout-defining bytes only.
        for start,end in ((143,156),(179,180),(212,216),(226,227)):
            d.require(old[start:end]==ext[start:end],"EXT_CSD geometry differs")
    for _,name,size in images:
        d.require((path/name).stat().st_size==size,"Invalid image size "+name)
    print("Dump and device preflight passed",flush=True)
    if args.action=="preflight": return
    d.confirm("Type RESTORE "+cid+" to continue (anything else cancels): ","RESTORE "+cid)
    for region,name,size in images:
        print("Scanning current device region:",region,flush=True)
        count=(size+CHUNK-1)//CHUNK
        actual=scan(r,cid,sectors,region,count)
        written=0
        with (path/name).open("rb") as f:
            order=list(range(count))
            if region=="user": order=order[1:]+order[:1]
            started=time.monotonic()
            for done,i in enumerate(order,1):
                f.seek(i*CHUNK)
                length=min(CHUNK,size-i*CHUNK)
                data=f.read(length)
                d.require(len(data)==length,"Dump changed during restore")
                if d.sha(data)!=actual[i]:
                    d.journal(args.journal,'writing',f'restore {region} chunk {i}')
                    write_block(r,cid,sectors,region,i,data)
                    written+=1
                d.progress(region,done,count,started)
        print(f"{region}: {written} written, {count-written} already matching.",flush=True)
        d.require(digest(r,cid,sectors,region,"verify")==sums[name],"Full restore hash mismatch")
    d.require(info(r,args.sd)[0]==cid,"CID changed")
    d.journal(args.journal,'verified','full restore')
    print("All full-dump regions verified",flush=True)

if __name__=="__main__": d.cli(main)

