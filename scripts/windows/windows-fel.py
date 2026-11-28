#!/usr/bin/env python3
"""Native Windows FEL RAM uploader. No disk writes, one SPL per cold boot."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request

SPL_SHA = "7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f"
ENTRY_SHA = "1a0044b4533ce91bb1f19f5fef9f1356242d3855cadd4087cc1c6a6ac22a21dd"
UBOOT_SHA = "ad00580889a797836b05ed8c718c11d5ccb014aa266707c4f41fa89d192fb87f"
URL = "https://xff.cz/kernels/bootloaders/pb/uboot.bin"
CHUNK = 65536

def require(ok, message):
    if not ok:
        raise RuntimeError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def prepare(kit):
    directory = kit / "fel-inputs"
    directory.mkdir(exist_ok=True)
    spl = directory / "pb626-spl.bin"
    if not spl.exists():
        local = directory / "uboot.bin"
        if local.exists():
            data = local.read_bytes()
        else:
            print("Fetching the historical hash-pinned FEL SPL from its original author...", flush=True)
            with urllib.request.urlopen(URL, timeout=45) as stream:
                data = stream.read(284993)
        require(len(data) == 284992 and sha(data) == UBOOT_SHA,
                "Original U-Boot unavailable or changed. Place verified uboot.bin or pb626-spl.bin in fel-inputs.")
        require(sha(data[:24576]) == SPL_SHA, "Historical SPL hash mismatch")
        with spl.open("xb") as out:
            out.write(data[:24576])
    require(spl.stat().st_size == 24576 and sha(spl.read_bytes()) == SPL_SHA, "Unknown FEL SPL")
    return spl

def invoke(exe, args, cwd, timeout=30, env=None, check=True):
    result = subprocess.run([str(exe), *map(str, args)], cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if check:
        require(result.returncode == 0, "FEL/tool failure: "+result.stdout.decode("ascii","replace")[-2000:])
    return result

def probe(exe, cwd):
    result = invoke(exe, ["version"], cwd, timeout=15)
    text = result.stdout.decode("ascii","replace")
    require(re.search(r"AWUSBFEX soc=00001625\(A13\)", text) is not None, "Unexpected FEL SoC: "+text)
    return text.strip()

def upload(exe, temp, data, base, label, device=None):
    for offset in range(0, len(data), CHUNK):
        block = data[offset:offset+CHUNK]
        (temp/"chunk.bin").write_bytes(block)
        back = temp/"readback.bin"
        if back.exists():
            back.unlink()
        address = f"0x{base+offset:08x}"
        invoke(exe, ["write", address, "chunk.bin", "read", address, len(block), "readback.bin"], temp)
        require(back.is_file() and back.read_bytes() == block, f"{label} RAM mismatch at {address}")
        if (offset+len(block)) % (1024*1024) == 0 or offset+len(block) == len(data):
            print(f"{label}: {offset+len(block):,}/{len(data):,} bytes verified", flush=True)

def boot(kit, profile):
    fel = kit/"host/sunxi-fel.exe"
    fdtget = kit/"host/fdtget.exe"
    spl = prepare(kit)
    entry = (kit/"host/direct-entry.bin").read_bytes()
    require(len(entry) == 52 and sha(entry) == ENTRY_SHA, "Invalid ARM entry stub")
    root = kit/"recovery"
    dtb = root/("pb626-elan-emmc-windows-rndis.dtb" if profile == "rndis" else "pb626-elan-emmc-backup.dtb")
    kernel = (root/"pb626-megi-zImage").read_bytes()
    ramfs = (root/"pb626-megi-initramfs.cpio.gz").read_bytes()
    tree = dtb.read_bytes()
    require(0 < len(kernel) < 0x1200000 and 0 < len(tree) < 0x1e00000
            and 0 < len(ramfs) < 0xb000000, "FEL DRAM overlap")
    require(kernel[0x24:0x28] == bytes.fromhex("18286f01") and tree[:4] == bytes.fromhex("d00dfeed"),
            "Invalid recovery kernel or DTB")
    with tempfile.TemporaryDirectory(prefix="pb626-fel-") as name:
        temp = Path(name)
        (temp/"board.dtb").write_bytes(tree)
        (temp/"spl.bin").write_bytes(spl.read_bytes())
        def fdt(kind, node, prop):
            return invoke(fdtget, ["-t", kind, "board.dtb", node, prop], temp).stdout.decode("ascii").strip()
        require(fdt("x","/memory@40000000","reg") == "40000000 10000000", "Wrong RAM geometry")
        require(fdt("s","/soc/mmc@1c11000","status") == "okay"
                and fdt("s","/soc/mmc@1c0f000","status") == "disabled", "Wrong recovery MMC policy")
        invoke(fdtget, ["board.dtb","/chosen","pb626,emmc-backup"], temp)
        rndis = invoke(fdtget, ["board.dtb","/chosen","pb626,windows-rndis"], temp, check=False)
        require((rndis.returncode == 0) == (profile == "rndis"), "Wrong USB recovery profile")
        require(int(fdt("x","/chosen","linux,initrd-start"),16) == 0x45000000
                and int(fdt("x","/chosen","linux,initrd-end"),16) == 0x45000000+len(ramfs), "Wrong initramfs extent")
        print(probe(fel,temp), flush=True)
        env = os.environ.copy()
        env["PB626_FEL_KEEP_MMU_OFF"] = "1"
        print("Initializing DRAM once. Do not retry without a full cold power cycle.", flush=True)
        invoke(fel, ["-v","version","spl","spl.bin","version"], temp, timeout=40, env=env)
        for data, base, label in ((kernel,0x42000000,"Kernel"),(tree,0x43200000,"DTB"),
                                  (ramfs,0x45000000,"Initramfs"),(entry,0x41000000,"Entry")):
            upload(fel,temp,data,base,label)
        print("All four images verified in RAM. Starting recovery...",flush=True)
        try:
            result = invoke(fel, ["-v","version","execute","0x41000000"], temp, timeout=25, check=False)
            print("FEL execute returned",result.returncode,"; recovery handshake still required.",flush=True)
        except subprocess.TimeoutExpired:
            print("FEL execute timed out; do not retry SPL. Check recovery enumeration.",flush=True)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("action",choices=("prepare","probe","boot","hello","ready","validate","test"))
    ap.add_argument("--profile",choices=("ncm","rndis"),default="ncm")
    ap.add_argument("--kit",type=Path,default=Path(__file__).resolve().parent)
    args=ap.parse_args()
    kit=args.kit.resolve()
    if args.action=="prepare":
        print("Verified FEL input:",prepare(kit))
    elif args.action=="probe":
        print(probe(kit/"host/sunxi-fel.exe",kit))
    elif args.action=="validate":
        import importlib
        direct=importlib.import_module("install-direct")
        rev, raw, spl=direct.checked_inputs(kit,"candidate")
        mapped=direct.mapped_chunks(kit/"native/pb626-rootfs.bmap.json")
        print(f"Validated {direct.kit_profile(kit)}: {rev}; raw kernel {len(raw)} bytes; {len(mapped)} mapped rootfs chunks; candidate {sha(spl)}")
    elif args.action=="test":
        import importlib
        direct=importlib.import_module("install-direct")
        dump=importlib.import_module("dump-network")
        recovery=direct.EthernetRecovery(windows=True)
        try:
            rows=direct.check_windows_recovery(recovery,kit)
            cid=next(x[4:] for x in rows if re.fullmatch(r"CID=[0-9a-f]{32}",x))
            recovery.test_transport()
            direct.require(recovery.lines("layout")==["1 1009664 14260224","2 73728 65536","8 275456 500736"],"Unexpected partition layout")
            other,sectors,ext=dump.info(recovery,False)
            direct.require(other==cid and sectors==15269888 and len(ext)==512,"Wrong eMMC geometry")
            for region in ("user","boot0","boot1"):
                data=dump.read_block(recovery,cid,sectors,region,0,direct.CHUNK)
                print(f"{region}: read-only 4 MiB verified {direct.sha(data)}",flush=True)
            print("Recovery diagnostic passed: identity, transport, layout, EXT_CSD, all three regions. No eMMC writes.")
        finally:
            recovery.close()
    elif args.action in ("hello","ready"):
        import importlib
        direct=importlib.import_module("install-direct")
        recovery=direct.EthernetRecovery(windows=True)
        try:
            direct.check_windows_recovery(recovery,kit,ready=args.action=="ready")
        finally:
            recovery.close()
        print("Same-build recovery"+(" and storage ready" if args.action=="ready" else " ready"))
    else:
        boot(kit,args.profile)
if __name__=="__main__":
    try:
        main()
    except (RuntimeError,OSError,ValueError,subprocess.SubprocessError) as exc:
        print("ERROR: "+str(exc),flush=True)
        raise SystemExit(1)
