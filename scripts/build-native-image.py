#!/usr/bin/env python3
"""Assemble a private, restorable firmware dump offline. Never open a block device."""
import argparse
import hashlib
import getpass
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import time
import zlib

SECTOR = 512
USER_SIZE = 15269888 * SECTOR
P1_START = 1009664
P1_SIZE = 14260224
BOOT_SIZE = 8192 * SECTOR
PREFIXES = {
    "6a3fcb2ed0c95d01799df6c9c3e7a3e6ed1045e4028fe1164a9ba44a81b56f4f",
    "2673c7b186a731b8b429812f4d55340c054fbbd5c42e0582b3a06794e12e8b63",
}
BT1 = "3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227"
SPL = "1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6"
WBF = "bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f"
NAMES = {
    "pb626-emmc-user.img": USER_SIZE,
    "pb626-emmc-boot0.img": BOOT_SIZE,
    "pb626-emmc-boot1.img": BOOT_SIZE,
    "pb626-emmc-ext-csd.bin": 512,
}

def require(ok, message):
    if not ok:
        raise SystemExit(message)

def regular(path, size=None):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode), f"Not a regular file: {path}")
    if size is not None:
        require(st.st_size == size, f"Unexpected size: {path}")
    return path

def digest(path, offset=0, size=None):
    h = hashlib.sha256()
    with regular(path).open("rb") as f:
        f.seek(offset)
        while size is None or size:
            data = f.read(8 * 1024 * 1024 if size is None else min(size, 8 * 1024 * 1024))
            if not data:
                require(size is None, f"Short read: {path}")
                break
            h.update(data)
            if size is not None:
                size -= len(data)
    return h.hexdigest()

def manifest(directory):
    result = {}
    for line in regular(directory / "SHA256SUMS").read_text().splitlines():
        m = re.fullmatch(r"([0-9a-fA-F]{64})\s+([A-Za-z0-9._-]+)", line)
        require(m and m[2] not in result, "Malformed or duplicate checksum")
        result[m[2]] = m[1].lower()
    return result

def checked(directory, checks, name, size=None):
    p = regular(directory / name, size)
    require(digest(p) == checks.get(name), f"Checksum mismatch: {name}")
    return p

def validate_raw(raw):
    require(len(raw) >= 512 and len(raw) % 512 == 0, "Raw kernel alignment")
    magic, hcrc, _, length, load, entry, dcrc = struct.unpack_from(">7I", raw)
    require(magic == 0x27051956 and load == entry == 0x40008000, "Raw kernel header")
    require(0 < length <= 0x800000 and 64 + length <= len(raw), "Raw kernel size")
    header = bytearray(raw[:64])
    header[4:8] = bytes(4)
    require(zlib.crc32(header) == hcrc and zlib.crc32(raw[64:64+length]) == dcrc, "Raw kernel CRC")
    require(len(raw) == (64 + length + 511) // 512 * 512 and not any(raw[64+length:]), "Raw padding")

def overlay(image, source, offset, length):
    regular(source, length)
    require(offset >= 0 and offset + length <= regular(image).stat().st_size, "Overlay outside image")
    with image.open("r+b") as out, source.open("rb") as inp:
        out.seek(offset)
        shutil.copyfileobj(inp, out, 8 * 1024 * 1024)
        out.flush()
        os.fsync(out.fileno())
    require(digest(image, offset, length) == digest(source), "Overlay verification failed")

def set_root_password(root, password_hash):
    require(re.fullmatch(r"\$6\$(?:rounds=[0-9]+\$)?[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}", password_hash), "Invalid SHA-512 crypt password hash")
    shadow = regular(root / "etc/shadow")
    rows = shadow.read_text().splitlines()
    require(sum(row.startswith("root:") for row in rows) == 1, "Missing or duplicate root shadow entry")
    for i, row in enumerate(rows):
        if row.startswith("root:"):
            fields = row.split(":")
            require(len(fields) == 9, "Malformed root shadow entry")
            fields[1] = password_hash
            fields[2] = str(int(time.time()) // 86400)
            rows[i] = ":".join(fields)
    shadow.write_text("\n".join(rows) + "\n")
    shadow.chmod(0o600)

def prompt_root_password(hash_file=None):
    if hash_file is not None:
        return regular(hash_file).read_text().strip()
    require(os.isatty(0), "Interactive terminal required, or use --root-password-hash-file")
    password = getpass.getpass("New native root password (at least 8 characters): ")
    require(len(password) >= 8 and "\n" not in password and "\r" not in password, "Password too short or invalid")
    require(password == getpass.getpass("Confirm root password: "), "Passwords do not match")
    return subprocess.check_output(["openssl", "passwd", "-6", "-stdin"], input=password + "\n", text=True).strip()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--backup", type=Path, required=True, help="Verified original or current full dump")
    p.add_argument("--system", type=Path, required=True, help="pb626-native-system CI artifact")
    p.add_argument("--spl", type=Path, required=True, help="Exact verified BT0-uncaged.bin")
    p.add_argument("--waveform", type=Path, required=True, help="Owner's original default.wbf")
    p.add_argument("--output", type=Path, required=True, help="New private directory")
    p.add_argument("--expected-cid", help="Original CID for a legacy backup")
    p.add_argument("--root-password-hash-file", type=Path, help="Private SHA-512 crypt hash file for noninteractive installation")
    p.add_argument("--accept-replace-p1", action="store_true", help="Replace p1 including all existing user data")
    a = p.parse_args()
    require(a.accept_replace_p1, "Explicit --accept-replace-p1 required")
    require(os.geteuid() == 0, "Run in Linux/WSL as root to preserve rootfs ownership")
    require(not a.output.exists(), "Output directory must not exist")
    os.umask(0o077)
    checks = manifest(a.backup)
    paths = {name: checked(a.backup, checks, name, size) for name, size in NAMES.items()}
    cid_name = "pb626-emmc-cid.txt"
    if (a.backup / cid_name).exists():
        cid = checked(a.backup, checks, cid_name).read_text().strip().lower()
        require(not a.expected_cid or a.expected_cid.lower() == cid, "CID mismatch")
    else:
        cid = (a.expected_cid or "").lower()
    require(re.fullmatch("[0-9a-f]{32}", cid), "Missing or invalid original CID")
    ext = paths["pb626-emmc-ext-csd.bin"].read_bytes()
    require(ext[179] == 0 and not any(ext[143:155]), "Unexpected eMMC partition configuration")
    source = paths["pb626-emmc-user.img"]
    require(digest(source, 0, 80*SECTOR) in PREFIXES, "Unknown factory/native boot prefix")
    for lba in (38192, 38704):
        require(digest(source, lba*SECTOR, 448*SECTOR) == BT1, "Unknown BT1 extent")
    with source.open("rb") as f:
        mbr = f.read(SECTOR)
    require(mbr[510:512] == b"\x55\xaa", "Invalid MBR")
    entries = [struct.unpack_from("<B3xB3xII", mbr, 446 + 16*i) for i in range(4)]
    require(entries[0][2:] == (P1_START,P1_SIZE) and entries[1][2:] == (73728,65536), "Unexpected p1/p2 geometry")
    require(P1_START+P1_SIZE == USER_SIZE//SECTOR, "Unexpected partition end")
    for _, typ, start, length in entries[2:]:
        require(not typ or typ in (5,15,133), "Unexpected extra primary partition")
    regular(a.spl, 24576)
    require(digest(a.spl) == SPL, "Not the hardware-tested SPL")
    require(digest(regular(a.waveform)) == WBF, "Not the validated factory waveform")
    syschecks = manifest(a.system)
    raw = checked(a.system,syschecks,"raw-linux.img")
    require(raw.stat().st_size <= 0x800000+512, "Raw image too large")
    validate_raw(raw.read_bytes())
    dtb = checked(a.system,syschecks,"pb626-elan-emmc-native.dtb")
    kernel = checked(a.system,syschecks,"pb626-native-zImage")
    def padded(p):
        data=p.read_bytes()
        return data+bytes(-len(data)%4)
    data=raw.read_bytes()
    n=struct.unpack_from(">I",data,12)[0]
    require(data[64:64+n].endswith(padded(kernel)+padded(dtb)), "Raw image/kernel/DTB mismatch")
    for path,status in [("/soc/mmc@1c0f000","disabled"),("/soc/mmc@1c11000","okay")]:
        value=subprocess.check_output(["fdtget","-t","s",str(dtb),path,"status"],text=True).strip()
        require(value==status,"Unsafe native DTB storage configuration")
    subprocess.run(["fdtget",str(dtb),"/chosen","pb626,emmc-root"],check=True)
    release=checked(a.system,syschecks,"KERNELRELEASE").read_text().strip()
    require(re.fullmatch(r"[A-Za-z0-9._+-]+",release),"Invalid kernel release")
    archive=checked(a.system,syschecks,"pb626-native-rootfs.tar.gz")
    # Extract trusted CI rootfs on a Linux filesystem, not Windows DrvFS.
    with tempfile.TemporaryDirectory(prefix="pb626-native-") as temp:
        work=Path(temp)
        root=work/"root"
        root.mkdir()
        subprocess.run(["tar","--numeric-owner","-xzf",str(archive.resolve()),"-C",str(root)],check=True)
        require((root/"lib/modules"/release/"modules.dep").is_file(),"Kernel modules missing")
        require((root/"etc/inittab").is_file() and (root/"sbin/openrc").is_file() and (root/"etc/init.d/pb626-desktop").is_file(), "OpenRC native init missing")
        set_root_password(root, prompt_root_password(a.root_password_hash_file))
        wave=root/"lib/firmware/pb626/default.wbf"
        wave.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(a.waveform,wave)
        wave.chmod(0o644)
        fs=work/"p1.ext4"
        with fs.open("wb") as f:
            f.truncate(P1_SIZE*SECTOR)
        subprocess.run(["mke2fs","-q","-F","-t","ext4","-b","4096","-E","lazy_itable_init=0,lazy_journal_init=0","-d",str(root),str(fs)],check=True)
        subprocess.run(["e2fsck","-fn",str(fs)],check=True)
        a.output.mkdir()
        user=a.output/source.name
        shutil.copyfile(source,user)
        overlay(user,a.spl,16*SECTOR,48*SECTOR)
        overlay(user,raw,80*SECTOR,raw.stat().st_size)
        overlay(user,fs,P1_START*SECTOR,P1_SIZE*SECTOR)
        # Verify every unchanged span, including MBR/EBR, BT1 and factory partitions.
        for start,end in [(0,16*SECTOR),(64*SECTOR,80*SECTOR),(80*SECTOR+raw.stat().st_size,P1_START*SECTOR)]:
            require(digest(user,start,end-start)==digest(source,start,end-start),"Unexpected change outside allowed regions")
        require(user.stat().st_size == USER_SIZE,"Output size mismatch")
        for name,path in paths.items():
            if name!=source.name:
                shutil.copyfile(path,a.output/name)
                require(digest(a.output/name)==checks[name],"Backup region copy mismatch")
        (a.output/cid_name).write_text(cid+"\n")
        names=list(NAMES)+[cid_name]
        contents="".join(f"{digest(a.output/name)}  {name}\n" for name in names)
        pending=a.output/"SHA256SUMS.partial"
        pending.write_text(contents)
        pending.replace(a.output/"SHA256SUMS")
    print("Firmware dump assembled and verified offline. Use restore preflight before any write.")

if __name__=="__main__":
    main()
