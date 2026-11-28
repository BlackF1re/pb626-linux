#!/usr/bin/env python3
"""Flash the paired CI artifact over USB NCM without a full eMMC dump.

Run on WSL/Linux with Python 3.7+, iproute2, openssl and cdc_ncm.
The old Recovery class is retained for emergency compatibility tests only.
"""
import argparse
import base64
import getpass
import gzip
import json
import socket
import shutil
import hashlib
import importlib
import os
import re
import secrets
import struct
import subprocess
import sys
import time
from pathlib import Path

P1_BYTES = 14260224 * 512
CHUNK = 4194304
WBF_HASH = 'bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f'
REMOTE = '/bin/sh /usr/libexec/pb626-install-direct.sh'


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


class Cancelled(Exception):
    pass


class TransportInterrupted(OSError):
    pass


def pin_session(path, identity):
    if path is None:
        return
    target=path.with_suffix(".identity.json")
    if target.exists():
        require(json.loads(target.read_text(encoding="utf-8"))==identity,
                "Resume refused: device, operation or input changed")
        return
    tmp=target.with_suffix(".tmp")
    with tmp.open("w",encoding="utf-8") as f:
        json.dump(identity,f,sort_keys=True)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp,target)


def confirm(prompt, expected):
    if input(prompt).strip() != expected:
        raise Cancelled("Cancelled by user; no additional writes requested")


def bootloader_warning(backup):
    return ("; BT0 update may prevent FEL recovery" +
            ("; NO BACKUP" if backup is None else "; backup verified"))


def confirm_write(description, cid, windows, verb):
    print(f"{description}. CID={cid}", flush=True)
    if windows:
        if input(f"{verb}? [y/N]: ").strip().lower() != "y":
            raise Cancelled("Cancelled")
    else:
        confirm(f"Type {verb} {cid} to continue: ",f"{verb} {cid}")


def progress(label, done, total, started):
    elapsed=max(time.monotonic()-started,0.001)
    width=24
    fill=min(width,int(width*done/max(total,1)))
    rate=done/elapsed
    remaining=max(0,int((total-done)/max(rate,0.001)))
    row=f"{label:<12} [{'#'*fill}{'-'*(width-fill)}] {100*done/max(total,1):5.1f}%  {done}/{total}  ETA {remaining//60:02d}:{remaining%60:02d}"
    if sys.stdout.isatty():
        print("\r"+row.ljust(78),end="\n" if done==total else "",flush=True)
    elif done==1 or done==total or done%16==0:
        print(row,flush=True)


def journal(path, state, detail=""):
    if path is None:
        return
    # A durable conservative record: mark *before* sending a write. A lost
    # ACK must never be interpreted as proof that nothing was written.
    if state=="preflight" and path.exists():
        # Never erase uncertainty from a prior attempt in the same session.
        return
    tmp=path.with_suffix(".tmp")
    with tmp.open("w",encoding="ascii") as stream:
        stream.write(state+"\n"+detail+"\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp,path)


def cli(main):
    try:
        main()
    except Cancelled as exc:
        print(str(exc),flush=True)
        raise SystemExit(2)
    except TransportInterrupted as exc:
        print("\nCONNECTION INTERRUPTED: "+str(exc),flush=True)
        raise SystemExit(75)
    except (KeyboardInterrupt, EOFError):
        print("\nOperation interrupted.",flush=True)
        raise SystemExit(130)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print("\nERROR: "+str(exc),flush=True)
        raise SystemExit(1)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def filehash(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def manifest(path):
    sums = {}
    for line in path.read_text().splitlines():
        m = re.fullmatch(r'([0-9a-fA-F]{64})  ([A-Za-z0-9_.+/-]+)', line)
        require(m is not None, 'Malformed native manifest')
        name = m[2][2:] if m[2].startswith('./') else m[2]
        require(not name.startswith('/') and '..' not in name.split('/') and name not in sums,
                'Unsafe/duplicate manifest entry')
        sums[name] = m[1].lower()
    return sums


class Recovery:
    def __init__(self, port):
        import serial
        self.s = serial.Serial(port, 115200, timeout=0.5, write_timeout=30,
                               rtscts=False, dsrdtr=False)
        self.s.dtr = True
        self.s.rts = True
        self.buf = bytearray()
        self.s.reset_input_buffer()
        self.s.write(b'\n')
        self.s.flush()

    def close(self):
        self.s.close()

    def line(self, deadline):
        while time.monotonic() < deadline:
            i = self.buf.find(b'\n')
            if i >= 0:
                raw = bytes(self.buf[:i])
                del self.buf[:i+1]
                return raw.decode('ascii', errors='replace').strip()
            self.buf.extend(self.s.read(max(1, min(self.s.in_waiting, 65536))))
            require(len(self.buf) < 1024*1024, 'Missing recovery line delimiter')
        raise RuntimeError('Recovery response timeout; no automatic write retry')

    def run(self, cmd, payload=None, timeout=90):
        marker = 'PBEND_' + secrets.token_hex(8)
        line = "{}; printf '\\n{}=%s\\n' $?\n".format(cmd, marker)
        require(len(line) < 3500, 'Shell command too long')
        self.s.write(line.encode('ascii'))
        self.s.flush()
        deadline = time.monotonic()+timeout
        rows, sent = [], False
        while True:
            row = self.line(deadline)
            if row == 'PB626_READY':
                require(payload is not None and not sent, 'Unexpected binary request')
                for i in range(0, len(payload), 16384):
                    piece = payload[i:i+16384]
                    require(self.s.write(piece) == len(piece), 'Short serial write')
                self.s.flush()
                sent = True
            elif re.fullmatch(re.escape(marker)+r'=[0-9]+', row):
                require(row == marker+'=0' and (payload is None or sent),
                        'Recovery command failed: '+cmd+'\n'+'\n'.join(rows[-12:]))
                return rows
            elif row:
                rows.append(row)

    def read_range(self, path, offset, size):
        # Text-only reads avoid interleaving character buffers and binary CDC frames.
        require(offset % 512 == 0 and size > 0, 'Invalid read range')
        out = bytearray()
        while len(out) < size:
            n = min(32768, ((size-len(out)+511)//512)*512)
            begin, end = 'PBDATA_'+secrets.token_hex(6), 'PBSTOP_'+secrets.token_hex(6)
            rows = self.run(
                "(set -o pipefail; printf '\\n{}\\n' && dd if={} bs=512 skip={} count={} status=none | base64 && printf '\\n{}\\n')"
                .format(begin, path, (offset+len(out))//512, n//512, end))
            require(begin in rows and end in rows, 'Missing text data framing')
            part = base64.b64decode(''.join(rows[rows.index(begin)+1:rows.index(end)]),
                                    validate=True)
            require(min(n, size-len(out)) <= len(part) <= n, 'Short/oversized read')
            out.extend(part)
        return bytes(out[:size])


class EthernetRecovery:
    """One bounded request/response over the dedicated USB NCM link."""
    def __init__(self, configure=True, address="169.254.62.1", port=6262, windows=False):
        self.address, self.port = address, port
        self.interface = None
        self.source_address = "169.254.62.2" if windows else None
        if windows:
            require(os.name == "nt", "Windows native mode requires Windows")
            require(self.lines("hello", timeout=5)==["PB626-NCM-1"], "Wrong recovery protocol")
        elif configure:
            require(os.name != "nt", "Run this installer in WSL or Linux")
            require(os.geteuid() == 0, "Run as root to configure USB NCM")
            require(shutil.which("ip"), "Install iproute2 in WSL/Linux")
            if shutil.which("modprobe"):
                subprocess.run(["modprobe","cdc_ncm"], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic()+45
            while time.monotonic() < deadline:
                interfaces = [p.name for p in Path("/sys/class/net").iterdir()
                              if (p/"address").read_text().strip().lower()
                              == "02:50:42:62:60:02"]
                require(len(interfaces) <= 1, "Multiple PB626 USB interfaces")
                if interfaces:
                    self.interface = interfaces[0]
                    break
                time.sleep(0.5)
            require(self.interface, "PB626 USB NCM missing: check usbipd and WSL cdc_ncm driver")
            subprocess.check_call(["ip","link","set",self.interface,"up"])
            subprocess.check_call(["ip","addr","replace","169.254.62.2/30","dev",self.interface])
            deadline = time.monotonic()+45
            while True:
                try:
                    require(self.lines("hello", timeout=3)==["PB626-NCM-1"],
                            "Wrong recovery protocol")
                    break
                except (OSError,TransportInterrupted):
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.5)
            print("USB NCM ready:", self.interface, flush=True)

    def close(self):
        pass

    def request(self, *args, payload=None, timeout=120, max_response=8*1024*1024):
        words = [str(x) for x in args]
        require(all(re.fullmatch(r"[A-Za-z0-9_./-]+", x) for x in words),
                "Invalid network request")
        header = ("PB626/1 "+" ".join(words)+"\n").encode("ascii")
        require(len(header) < 512, "Oversized request header")
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(timeout)
                if self.interface:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                                 self.interface.encode()+b"\0")
                if self.interface or self.source_address:
                    s.bind((self.source_address or "169.254.62.2",0))
                s.connect((self.address,self.port))
                s.sendall(header)
                if payload is not None:
                    s.sendall(payload)
                s.shutdown(socket.SHUT_WR)
                out = bytearray()
                while True:
                    part = s.recv(65536)
                    if not part:
                        break
                    out.extend(part)
                    require(len(out) <= max_response, "Oversized recovery response")
        except OSError as exc:
            raise TransportInterrupted(f"{' '.join(words)}: {exc}") from exc
        match = re.search(rb"\nPB626_STATUS ([0-9]+)\n\Z", out)
        if match is None:
            raise TransportInterrupted(f"{' '.join(words)}: incomplete TCP response; verify media before resuming")
        require(match[1] == b"0", "Recovery command failed: "+
                bytes(out[:match.start()])[-1000:].decode("ascii","replace"))
        return bytes(out[:match.start()])

    def lines(self, *args, **kwargs):
        return self.request(*args, **kwargs).decode("ascii").splitlines()

    def run(self, cmd, payload=None, timeout=120):
        require(cmd.startswith(REMOTE+" "), "Unsupported direct command")
        return [x.strip() for x in self.lines("direct", *cmd[len(REMOTE)+1:].split(),
                                               payload=payload, timeout=timeout) if x.strip()]

    def read_range(self, path, offset, size):
        require(path == "/dev/mmcblk2p2" and offset % 512 == 0 and size > 0,
                "Invalid calibration read")
        out = bytearray()
        while len(out) < size:
            count = min(64,(size-len(out)+511)//512)
            data = self.request("read-p2", (offset+len(out))//512, count)
            require(len(data) == count*512, "Short calibration read")
            out.extend(data)
        return bytes(out[:size])

    def test_transport(self):
        payload = os.urandom(CHUNK)
        start = time.monotonic()
        require(self.lines("test",sha(payload),payload=payload)==["TRANSFER_OK"],
                "USB Ethernet transfer test failed")
        print("USB TCP verified: %.2f MiB/s" %
              (4/max(time.monotonic()-start,0.001)),flush=True)


def mapped_chunks(path, total=P1_BYTES):
    return set(rootfs_map(path,total)[0])


def rootfs_map(path, total=P1_BYTES, require_hashes=False):
    data = json.loads(path.read_text())
    count = (total+CHUNK-1)//CHUNK
    require(data.get("version") in (1,2) and data.get("image_bytes")==total
            and data.get("chunk_bytes")==CHUNK, "Invalid rootfs map geometry")
    values = data.get("mapped")
    require(isinstance(values,list) and values and values[0]==0
            and all(type(x) is int and 0<=x<count for x in values)
            and values==sorted(set(values)), "Invalid rootfs map entries")
    hashes=data.get("sha256")
    if data["version"]==2:
        require(isinstance(hashes,dict) and set(hashes)=={str(i) for i in values}
                and all(isinstance(h,str) and re.fullmatch(r"[0-9a-f]{64}",h) for h in hashes.values()),
                "Invalid rootfs chunk hashes")
    else:
        require(not require_hashes,"This Windows bundle requires a version-2 hashed rootfs map")
        hashes={}
    return values,{int(i):h for i,h in hashes.items()}


def get_wbf(r):
    dev = '/dev/mmcblk2p2'
    boot = r.read_range(dev, 0, 512)
    require(boot[510:512] == b'\x55\xaa', 'Invalid FAT boot sector')
    bps = struct.unpack_from('<H', boot, 11)[0]
    spc = boot[13]
    reserved = struct.unpack_from('<H', boot, 14)[0]
    fats = boot[16]
    entries = struct.unpack_from('<H', boot, 17)[0]
    fat_size = struct.unpack_from('<H', boot, 22)[0]
    total = struct.unpack_from('<H', boot, 19)[0] or struct.unpack_from('<I', boot, 32)[0]
    require(bps == 512 and spc in (1,2,4,8,16,32,64,128) and reserved > 0
            and fats in (1,2) and entries > 0 and fat_size > 0 and 0 < total <= 65536,
            'Unexpected FAT16 geometry')
    root_sector = reserved+fats*fat_size
    root_sectors = (entries*32+511)//512
    data_sector = root_sector+root_sectors
    clusters = (total-data_sector)//spc
    require(4085 <= clusters < 65525 and root_sectors <= 256
            and fat_size*256 >= clusters+2, 'Unsupported FAT16')
    root = r.read_range(dev, root_sector*512, root_sectors*512)
    fat = r.read_range(dev, reserved*512, fat_size*512)

    def read_file(name, limit):
        entry = None
        for i in range(0, entries*32, 32):
            d = root[i:i+32]
            if d[0] == 0:
                break
            if d[0] != 0xe5 and not d[11]&0x18 and d[:11].upper() == name:
                entry = d
                break
        require(entry is not None, 'Missing factory file '+str(name))
        cluster = struct.unpack_from('<H', entry, 26)[0]
        size = struct.unpack_from('<I', entry, 28)[0]
        require(0 < size <= limit, 'Unexpected factory file size')
        out, seen = bytearray(), set()
        for _ in range((size+spc*512-1)//(spc*512)):
            require(2 <= cluster < clusters+2 and cluster not in seen, 'Invalid FAT chain')
            seen.add(cluster)
            out.extend(r.read_range(dev, (data_sector+(cluster-2)*spc)*512, spc*512))
            cluster = struct.unpack_from('<H', fat, cluster*2)[0]
        require(cluster >= 0xfff8, 'FAT chain length mismatch')
        return bytes(out[:size])

    wbf = read_file(b'DEFAULT WBF', 16*1024*1024)
    require(sha(wbf) == WBF_HASH, 'Unknown waveform')
    require(read_file(b'VCOM       ', 512).decode('ascii').strip() == '-2440',
            'Unknown factory VCOM')
    return wbf


def kit_profile(kit):
    path=kit/'PROFILE'
    profile=path.read_text().strip() if path.is_file() else 'standard'
    require(profile == 'standard','Invalid kit profile')
    return profile


def resume_spl_path(kit):
    return kit/'bootloader'/'BT0-uncaged-resume.bin'


def check_windows_recovery(r, kit, ready=True):
    expected = '{} {} {}'.format((kit/'native/BUILD-COMMIT').read_text().strip(),
                                kit_profile(kit), filehash(resume_spl_path(kit)))
    require(r.lines('identity',timeout=5)==[expected],
            'Wrong RAM recovery build/profile; boot recovery from this bundle')
    if not ready:
        return []
    rows=r.lines('probe',timeout=10)
    require(sum(bool(re.fullmatch(r'CID=[0-9a-f]{32}',row)) for row in rows)==1,
            'eMMC not ready or not qualified')
    return rows


def checked_inputs(kit, spl_mode='qualified'):
    native = kit/'native'
    rev = (native/'BUILD-COMMIT').read_text().strip()
    require(re.fullmatch('[0-9a-f]{40}', rev)
            and (kit/'recovery/BUILD-COMMIT').read_text().strip() == rev,
            'Native/recovery commits differ')
    sums = manifest(native/'SHA256SUMS')
    for name in ('BUILD-COMMIT', 'KERNELRELEASE', 'raw-linux.img', 'pb626-rootfs.ext4.gz', 'pb626-rootfs.bmap.json',
                 'pb626-bt0-menu.raw', 'pb626-native-zImage', 'pb626-elan-emmc-native.dtb'):
        require(filehash(native/name) == sums.get(name), 'Invalid artifact: '+name)
    sys.path.insert(0, str(kit/'source/scripts'))
    builder = importlib.import_module('build-native-image')
    raw = (native/'raw-linux.img').read_bytes()
    require(0 < len(raw) <= 0x800000+512, 'Kernel too large')
    builder.validate_raw(raw)
    pad = lambda x: x+bytes(-len(x)%4)
    length = struct.unpack_from('>I', raw, 12)[0]
    require(raw[64:64+length].endswith(pad((native/'pb626-native-zImage').read_bytes())+
                                      pad((native/'pb626-elan-emmc-native.dtb').read_bytes())),
            'Kernel/DTB mismatch')
    sys.path.insert(0, str(kit/'source/BT0-uncaged'))
    bt0 = importlib.import_module('build')
    spl = None
    if spl_mode == 'qualified':
        spl = bytes(bt0.build(kit/'fel-inputs/pb626-spl.bin', native/'pb626-bt0-menu.raw'))
    elif spl_mode == 'resume':
        candidate = resume_spl_path(kit)
        spl = candidate.read_bytes()
        bt0.verify(spl)
        sums = manifest(kit/'SHA256SUMS')
        require(sha(spl) == sums.get('bootloader/'+candidate.name), 'Bootloader manifest mismatch')
    else:
        require(spl_mode == 'keep', 'Unknown SPL mode')
    return rev, raw, spl


def image_blocks(stream, total):
    for i in range((total+CHUNK-1)//CHUNK):
        size = min(CHUNK, total-i*CHUNK)
        data = stream.read(size)
        require(len(data) == size, 'Short uncompressed image')
        # Detect trailing data before the final write.
        if i == (total+CHUNK-1)//CHUNK-1:
            require(not stream.read(1), 'Oversized uncompressed image')
        yield i, data


def send_block(r, cid, kind, i, data):
    packed = gzip.compress(data, compresslevel=1)
    fmt, payload = ('gzip', packed) if len(packed) < len(data) else ('raw', data)
    rows = r.run('{} write {} {} {} {} {} {} {}'.format(
        REMOTE, cid, kind, i, fmt, len(payload), sha(data), len(data)), payload, timeout=240)
    require('PB626_WRITTEN' in rows, 'Missing verified write acknowledgement')


def matching_block(r, cid, kind, index, data):
    rows=r.run('{} chunk-hash {} {} {} {}'.format(REMOTE,cid,kind,index,len(data)))
    require(len(rows)==1 and re.fullmatch(r'BLOCK '+str(index)+r' [0-9a-f]{64}',rows[0]),
            'Invalid device chunk-hash acknowledgement')
    return rows[0].split()[2]==sha(data)


def write_if_different(r, cid, kind, index, data, record=None, compare=True):
    # A journal is advisory; actual media bytes decide whether to skip.
    # This also handles a write that completed just before its ACK was lost.
    if compare and matching_block(r,cid,kind,index,data):
        return False
    journal(record,'writing',f'{kind} chunk {index}')
    send_block(r,cid,kind,index,data)
    return True


def hash_password(distro, openssl=None):
    require(sys.stdin.isatty(), 'Interactive terminal required for password entry')
    while True:
        password = getpass.getpass('Root password (min 4): ')
        if len(password) < 4 or any(c in password for c in ('\n','\r','\0')):
            print('Use at least 4 characters, no line breaks.',flush=True)
            continue
        if password == getpass.getpass('Confirm root password: '):
            break
        print('Passwords differ.',flush=True)
    cmd = [str(openssl or 'openssl'), 'passwd', '-6', '-stdin']
    if os.name == 'nt' and openssl is None:
        cmd = ['wsl.exe', '-d', distro, '-u', 'root', '--']+cmd
    result = subprocess.check_output(cmd, input=(password+'\n').encode('utf-8')).strip()
    require(re.fullmatch(rb'\$6\$[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}', result),
            'Invalid SHA-512 crypt output')
    return result+b'\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--kit', type=Path, default=Path(__file__).resolve().parent)
    ap.add_argument('--port', help='Legacy compatibility; ACM is not used for bulk data')
    ap.add_argument('--distro', default='Ubuntu')
    ap.add_argument('--windows', action='store_true', help='Native Windows TCP; adapter configured by launcher')
    ap.add_argument('--spl', choices=('keep','qualified','resume'), default='qualified')
    partial=ap.add_mutually_exclusive_group()
    partial.add_argument('--spl-only', action='store_true', help='Only replace the selected primary SPL')
    partial.add_argument('--rootfs-only',action='store_true',help='Replace rootfs only if exact paired kernel is installed')
    partial.add_argument('--kernel-only',action='store_true',help='Replace kernel only if installed modules match the bundle')
    ap.add_argument('--bootloader-backup', type=Path, help='Verified full dump for BT0 update')
    ap.add_argument('--journal',type=Path,help='Local write-state record')
    ap.add_argument('--allow-no-backup', action='store_true',
                    help='Allow Windows BT0 update without a dump')
    args = ap.parse_args()
    kit = args.kit.resolve()
    require(not args.spl_only or args.spl != 'keep', 'No SPL selected')
    require(not (args.rootfs_only or args.kernel_only) or (args.windows and args.spl=='keep'),
            'Partial kernel/rootfs operations preserve BT0 and require native Windows recovery')
    require(args.spl != 'resume' or args.windows, 'Resume SPL requires the authorized Windows recovery image')
    require(not args.allow_no_backup or (args.windows and args.spl == 'resume' and args.bootloader_backup is None),
            'Backup waiver is only for Windows BT0 without a supplied dump')
    kit_profile(kit)
    require(not args.windows or (args.spl=='resume' and not (args.spl_only or args.rootfs_only or args.kernel_only)),
            'Install the kernel, rootfs and resume bootloader as one pair')
    rev, raw, spl = checked_inputs(kit, args.spl)
    journal(args.journal,'preflight')
    print('Paired flashable firmware:', rev, flush=True)
    theme_module = importlib.import_module('pb626_sleep_theme')
    mapped_list,expected_chunks=rootfs_map(kit/'native/pb626-rootfs.bmap.json',require_hashes=args.windows)
    mapped=set(mapped_list)
    r = EthernetRecovery(windows=args.windows)
    try:
        rows = check_windows_recovery(r,kit) if args.windows else r.lines('probe')
        r.test_transport()
        ids = [x[4:] for x in rows if re.fullmatch(r'CID=[0-9a-f]{32}', x)]
        require(len(ids) == 1, 'Unqualified eMMC')
        cid = ids[0]
        pin_session(args.journal,{"operation":"firmware","cid":cid,"revision":rev,
                    "manifest":filehash(kit/'native/SHA256SUMS'),"spl":args.spl,
                    "spl_only":args.spl_only,"rootfs_only":args.rootfs_only,
                    "kernel_only":args.kernel_only})
        print('Verified reader CID:',cid,flush=True)
        require(r.lines('layout')==['1 1009664 14260224','2 73728 65536','8 275456 500736'],
                'Unexpected partition layout')
        if args.spl == 'keep':
            current = r.run('{} bootloader-hash {}'.format(REMOTE,cid))
            allowed = {'1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6'}
            candidate = resume_spl_path(kit)
            if candidate.is_file():
                allowed.add(filehash(candidate))
            require(len(current)==1 and current[0] in allowed,
                    'Installed BT0 is not recognized; choose qualified installation instead of keep')
        if args.spl == 'resume':
            require(r.run('{} spl-check {}'.format(REMOTE,cid)) == [sha(spl)],
                    'Running recovery does not authorize this exact same-run bootloader')
            if args.bootloader_backup is None:
                require(args.allow_no_backup, 'Supply a verified backup or explicitly waive it')
            else:
                backup = args.bootloader_backup
                sums = manifest(backup/'SHA256SUMS')
                sizes = {'pb626-emmc-user.img':15269888*512, 'pb626-emmc-boot0.img':CHUNK,
                         'pb626-emmc-boot1.img':CHUNK, 'pb626-emmc-ext-csd.bin':512}
                require((backup/'pb626-emmc-cid.txt').read_text().strip()==cid
                        and filehash(backup/'pb626-emmc-cid.txt')==sums.get('pb626-emmc-cid.txt'),
                        'Backup belongs to a different card or CID is corrupt')
                print('Verifying full recovery backup...',flush=True)
                for name,size in sizes.items():
                    path=backup/name
                    require(path.stat().st_size==size and filehash(path)==sums.get(name),'Invalid backup: '+name)
            print('Bootloader SHA256:', sha(spl), flush=True)
        if args.rootfs_only:
            print('Checking the installed raw kernel against this bundle...',flush=True)
            for i,offset in enumerate(range(0,len(raw),CHUNK)):
                require(matching_block(r,cid,'kernel',i,raw[offset:offset+CHUNK]),
                        'Rootfs-only requires the exact paired kernel; use paired installation')
        if args.kernel_only:
            release=(kit/'native/KERNELRELEASE').read_text().strip()
            module_file=kit/'native/pb626-modules.sha256'
            require(filehash(module_file)==manifest(kit/'native/SHA256SUMS').get(module_file.name),
                    'Missing or invalid module tree manifest')
            digest=module_file.read_text().strip()
            require(re.fullmatch(r'[A-Za-z0-9_.+-]+',release) and re.fullmatch(r'[0-9a-f]{64}',digest),
                    'Invalid module manifest')
            print('Checking the installed module tree and native rootfs (read-only)...',flush=True)
            require(r.run('{} modules-check {} {} {}'.format(REMOTE,cid,release,digest))==['PB626_MODULES_VERIFIED'],
                    'Installed modules do not match; use paired installation')
            confirm_write('Replace kernel/DTB only',cid,args.windows,'KERNEL')
            for i,offset in enumerate(range(0,len(raw),CHUNK)):
                write_if_different(r,cid,'kernel',i,raw[offset:offset+CHUNK],args.journal)
            require('CID='+cid in r.lines('probe'),'Final identity check failed')
            journal(args.journal,'verified','kernel only')
            print('SUCCESS: kernel/DTB verified; rootfs and BT0 unchanged.',flush=True)
            return
        if args.spl_only:
            release=(kit/'native/KERNELRELEASE').read_text().strip()
            require(re.fullmatch(r'[A-Za-z0-9_.+-]+',release), 'Invalid kernel release')
            print('Checking installed native kernel and matching modules (read-only)...',flush=True)
            try:
                rows=r.run('{} native-check {} {} {} {}'.format(REMOTE,cid,len(raw),sha(raw),release))
                require('PB626_NATIVE_VERIFIED' in rows,'Missing native compatibility confirmation')
            except RuntimeError as exc:
                raise RuntimeError('BT0-only update requires the native kernel/rootfs from this kit. Use paired installation first. '+str(exc)) from exc
            description = 'Replace BT0 only (LBA 16-63)'
            if args.spl == 'resume':
                description += bootloader_warning(args.bootloader_backup)
            confirm_write(description,cid,args.windows,'BOOTLOADER')
            write_if_different(r,cid,'spl-candidate' if args.spl == 'resume' else 'spl',0,spl,args.journal,args.windows)
            require('CID='+cid in r.lines('probe'), 'Final identity check failed')
            journal(args.journal,'verified','BT0 only')
            print('SUCCESS: BT0 alone written and read back; rootfs and kernel unchanged.', flush=True)
            return
        print('Reading factory waveform, VCOM and sleep artwork over TCP...', flush=True)
        personal = {'default.wbf': get_wbf(r)}
        theme = r.request('theme')
        require(len(theme)==770198, 'Unsupported stock theme size')
        personal.update(theme_module.decode_theme(theme))
        require('CID='+cid in r.lines('probe'), 'CID changed')
        personal['password'] = hash_password(args.distro, kit/'host/openssl.exe' if args.windows else None)
        description = 'Replace p1 (all files)' if args.rootfs_only else 'Replace p1 (all files) and kernel/DTB'
        if spl is not None:
            description += ' and BT0'
        if args.spl == 'resume':
            description += bootloader_warning(args.bootloader_backup)
        confirm_write(description,cid,args.windows,'FLASH')
        # Verify recovery supports the new protocol before any write. This operation
        # only creates a private directory in RAM, not on eMMC.
        r.run('{} reset-data {}'.format(REMOTE, cid))
        for name, data in personal.items():
            for offset in range(0, len(data), 1024*1024):
                piece = data[offset:offset+1024*1024]
                r.run('{} file {} {} {} {} {}'.format(REMOTE,cid,name,offset,len(piece),sha(piece)), piece)
        require('PB626_DATA_VERIFIED' in r.run('{} check-data {}'.format(REMOTE,cid)),
                'Personalization input verification failed')
        print('Streaming sparse ext4: {} mapped chunks of 1741'.format(len(mapped)),flush=True)
        done = written = 0
        if args.windows:
            print('Comparing mapped chunks with the actual eMMC; matching chunks are not written again.',flush=True)
        started=time.monotonic()
        with gzip.open(str(kit/'native/pb626-rootfs.ext4.gz'), 'rb') as image:
            for i, data in image_blocks(image, P1_BYTES):
                if i not in mapped:
                    require(data == bytes(len(data)), 'Nonzero omitted rootfs chunk')
                    continue
                require(not expected_chunks or sha(data)==expected_chunks[i],
                        f'Rootfs source chunk {i} differs from the verified bundle')
                written += write_if_different(r,cid,'rootfs',i,data,args.journal,args.windows)
                done += 1
                progress('Rootfs',done,len(mapped),started)
        require(done==len(mapped), 'Incomplete sparse rootfs')
        print(f'Rootfs: {written} written, {done-written} already matching.',flush=True)
        print('Personalizing rootfs on device...', flush=True)
        journal(args.journal,'writing','rootfs personalization')
        require('PB626_PERSONALIZED' in r.run('{} personalize {}'.format(REMOTE,cid), timeout=240),
                'Personalization failed')
        print('Checking remaining selected components...', flush=True)
        images = [] if args.rootfs_only else [('kernel', raw)]
        if spl is not None:
            images.append(('spl-candidate' if args.spl == 'resume' else 'spl', spl))
        for kind, image in images:
            started=time.monotonic()
            total=(len(image)+CHUNK-1)//CHUNK
            for i, offset in enumerate(range(0,len(image),CHUNK)):
                write_if_different(r,cid,kind,i,image[offset:offset+CHUNK],args.journal,args.windows)
                progress(kind,i+1,total,started)
        require('CID='+cid in r.lines('probe'),
                'Final identity check failed')
        journal(args.journal,'verified','firmware')
        print(('SUCCESS: p1 written; kernel preserved; BT0 ' if args.rootfs_only else
               'SUCCESS: p1 and kernel written; BT0 ')+('preserved' if spl is None else 'written and verified')+
              '; all other eMMC regions preserved.', flush=True)
    finally:
        r.close()


if __name__ == '__main__':
    cli(main)
