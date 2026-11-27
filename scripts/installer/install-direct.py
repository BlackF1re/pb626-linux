#!/usr/bin/env python3
"""Flash the paired CI artifact without creating or reading a full eMMC dump.

Windows: Python 3.7+ and pyserial; WSL openssl for password hashing.
Linux: Python 3.7+, pyserial and openssl. Invoked by PB626.ps1.
"""
import argparse
import base64
import getpass
import gzip
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


def checked_inputs(kit):
    native = kit/'native'
    rev = (native/'BUILD-COMMIT').read_text().strip()
    require(re.fullmatch('[0-9a-f]{40}', rev)
            and (kit/'recovery/BUILD-COMMIT').read_text().strip() == rev,
            'Native/recovery commits differ')
    sums = manifest(native/'SHA256SUMS')
    for name in ('BUILD-COMMIT', 'raw-linux.img', 'pb626-rootfs.ext4.gz',
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
    spl = bytes(bt0.build(kit/'fel-inputs/pb626-spl.bin', native/'pb626-bt0-menu.raw'))
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


def hash_password(distro):
    password = getpass.getpass('New root password (at least 4 characters): ')
    require(len(password) >= 4 and '\n' not in password and '\r' not in password
            and '\0' not in password, 'Invalid password')
    require(password == getpass.getpass('Confirm root password: '), 'Passwords differ')
    cmd = ['openssl', 'passwd', '-6', '-stdin']
    if os.name == 'nt':
        cmd = ['wsl.exe', '-d', distro, '-u', 'root', '--']+cmd
    result = subprocess.check_output(cmd, input=(password+'\n').encode('utf-8')).strip()
    require(re.fullmatch(rb'\$6\$[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}', result),
            'Invalid SHA-512 crypt output')
    return result+b'\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--kit', type=Path, default=Path(__file__).resolve().parent)
    ap.add_argument('--port', required=True)
    ap.add_argument('--distro', default='Ubuntu')
    args = ap.parse_args()
    require(re.fullmatch(r'COM[1-9][0-9]*|/dev/ttyACM[0-9]+', args.port), 'Invalid ACM port')
    kit = args.kit.resolve()
    rev, raw, spl = checked_inputs(kit)
    print('Paired flashable firmware:', rev, flush=True)
    theme_module = importlib.import_module('pb626_sleep_theme')
    r = Recovery(args.port)
    try:
        rows = r.run('test -e /run/pb626-emmc-ready && /bin/sh /usr/libexec/pb626-restore-fast.sh probe')
        ids = [x[4:] for x in rows if re.fullmatch(r'CID=[0-9a-f]{32}', x)]
        require(len(ids) == 1, 'Unqualified eMMC')
        cid = ids[0]
        for part, start, size in ((1,1009664,14260224), (2,73728,65536), (8,275456,500736)):
            r.run('test "$(cat /sys/class/block/mmcblk2p{}/start)" = {} && test "$(cat /sys/class/block/mmcblk2p{}/size)" = {}'.format(part,start,part,size))
        print('Reading only factory waveform, VCOM and sleep artwork...', flush=True)
        personal = {'default.wbf': get_wbf(r)}
        r.run('mkdir -p /run/pb626-theme && mount -t ext4 -o ro,noload /dev/mmcblk2p8 /run/pb626-theme')
        try:
            require('770198' in r.run('wc -c < /run/pb626-theme/themes/Line.pbt'),
                    'Unsupported stock theme size')
            theme = r.read_range('/run/pb626-theme/themes/Line.pbt', 0, 770198)
            personal.update(theme_module.decode_theme(theme))
        finally:
            r.run('busybox umount /run/pb626-theme')
        require('CID='+cid in r.run('/bin/sh /usr/libexec/pb626-restore-fast.sh probe'),
                'CID changed')
        personal['password'] = hash_password(args.distro)
        print('Only p1, raw kernel/DTB and tested BT0 will be replaced. No full backup.', flush=True)
        require(input('Type FLASH '+cid+' to continue: ') == 'FLASH '+cid, 'Cancelled')
        # Verify recovery supports the new protocol before any write. This operation
        # only creates a private directory in RAM, not on eMMC.
        r.run('{} reset-data {}'.format(REMOTE, cid))
        total = (P1_BYTES+CHUNK-1)//CHUNK
        print('Streaming ready-made ext4 from Actions ({} blocks)...'.format(total), flush=True)
        with gzip.open(str(kit/'native/pb626-rootfs.ext4.gz'), 'rb') as image:
            for i, data in image_blocks(image, P1_BYTES):
                send_block(r, cid, 'rootfs', i, data)
                if i == 0 or (i+1)%16 == 0 or i+1 == total:
                    print('rootfs: {}/{} verified'.format(i+1, total), flush=True)
        print('Personalizing rootfs on device...', flush=True)
        for name, data in personal.items():
            for offset in range(0, len(data), 1024*1024):
                piece = data[offset:offset+1024*1024]
                r.run('{} file {} {} {} {} {}'.format(REMOTE,cid,name,offset,len(piece),sha(piece)), piece)
        require('PB626_PERSONALIZED' in r.run('{} personalize {}'.format(REMOTE,cid), timeout=240),
                'Personalization failed')
        print('Writing kernel/DTB and BT0 (last)...', flush=True)
        for kind, image in (('kernel',raw), ('spl',spl)):
            for i, offset in enumerate(range(0,len(image),CHUNK)):
                send_block(r,cid,kind,i,image[offset:offset+CHUNK])
        require('CID='+cid in r.run('/bin/sh /usr/libexec/pb626-restore-fast.sh probe'),
                'Final identity check failed')
        print('SUCCESS: p1, kernel and BT0 written; all other eMMC regions preserved.', flush=True)
    finally:
        r.close()


if __name__ == '__main__':
    main()
