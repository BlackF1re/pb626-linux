#!/usr/bin/env python3
"""Exercise binary transfers through a pseudoterminal, without a block device."""

import gzip
import hashlib
import os
from pathlib import Path
import select
import shlex
import subprocess
import sys
import tempfile


def transfer(script, arguments, payload, success=True):
    master, slave = os.openpty()
    try:
        with subprocess.Popen(
            ["busybox", "sh", str(script), *arguments],
            stdin=slave,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        ) as device:
            try:
                if not select.select([device.stdout], [], [], 5)[0]:
                    raise RuntimeError("Timed out waiting for the device")
                if device.stdout.readline() != b"\n":
                    raise RuntimeError("Missing ready prefix")
                if device.stdout.readline() != b"PB626_READY\n":
                    raise RuntimeError("Missing binary ready signal")
                remaining = memoryview(payload)
                while remaining:
                    count = os.write(master, remaining[:65536])
                    remaining = remaining[count:]
                response, _ = device.communicate(timeout=20)
                if (device.returncode == 0) != success:
                    raise RuntimeError(response.decode(errors="replace"))
                return response
            finally:
                if device.poll() is None:
                    device.kill()
    finally:
        os.close(master)
        os.close(slave)


def main():
    helper = Path(sys.argv[1]).read_bytes()
    source = Path(__file__).with_name("pb626-restore-fast.sh").read_text()
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        script = temp / "device.sh"
        source = source.replace("/run/pb626-fast.XXXXXX", str(temp / "data.XXXXXX"))
        source = source.replace("/run/pb626-restore-scan", shlex.quote(str(temp / "scanner")))
        script.write_text(source)

        compressed = gzip.compress(helper)
        checksum = hashlib.sha256(compressed).hexdigest()
        transfer(script, ["load-scanner", str(len(compressed)), checksum], compressed)

        data = bytes(range(256)) * (4 * 1024 * 1024 // 256)
        checksum = hashlib.sha256(data).hexdigest()
        result = transfer(script, ["test-transfer", str(len(data)), checksum], data)
        if result != f"BLOCK 0 {checksum}\n".encode():
            raise RuntimeError(f"Invalid scan response: {result!r}")

        result = transfer(
            script, ["test-transfer", str(len(data)), "0" * 64], data, success=False
        )
        if b"Payload SHA-256 mismatch" not in result:
            raise RuntimeError(f"Invalid corruption response: {result!r}")

        # Exercise the backup sender with a regular file instead of eMMC.
        image = temp / "mock-user.img"
        image.write_bytes(data)
        mock = source.replace("/dev/mmcblk2\n", str(image) + "\n", 1)
        mock = mock.replace("operation=$1", "unmounted() { :; }\nblockdev() { test \"$1\" = --getro && echo 1; }\noperation=$1", 1)
        script.write_text(mock)
        master, slave = os.openpty()
        try:
            result = subprocess.run(
                ["busybox", "sh", str(script), "backup-read", "user", "0"],
                stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=20, check=True,
            )
            expected = f"\nPB626_DATA {len(data)} {checksum}\n".encode() + data + b"\nPB626_DATA_END\n"
            if result.stdout != expected:
                raise RuntimeError("Invalid outbound frame")
            # Same fixed raw hash and bounded frame for compressed or zero blocks.
            for block, wanted_format in ((data, "gzip"), (bytes(len(data)), "zero"),
                                         (os.urandom(len(data)), "raw")):
                image.write_bytes(block)
                packed = subprocess.run(
                    ["busybox", "sh", str(script), "backup-read-packed", "user", "0"],
                    stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    timeout=30, check=True,
                ).stdout
                header, rest = packed[1:].split(b"\n", 1)
                tag, length, raw_hash, fmt = header.decode().split()
                length = int(length)
                assert tag == "PB626_DATA" and fmt == wanted_format
                assert 0 <= length <= len(block) and rest[length:] == b"\nPB626_DATA_END\n"
                payload = rest[:length]
                decoded = bytes(len(block)) if fmt == "zero" else gzip.decompress(payload) if fmt == "gzip" else payload
                assert decoded == block and hashlib.sha256(decoded).hexdigest() == raw_hash
            result = subprocess.run(
                ["busybox", "sh", str(script), "backup-read", "boot0", "1"],
                stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=5,
            )
            if result.returncode == 0 or b"Block index outside region" not in result.stderr:
                raise RuntimeError("Out-of-range backup read not rejected")
        finally:
            os.close(master)
            os.close(slave)

        # SD operations on a regular file: use the real region selection,
        # length arithmetic, framing, decoder and readback. Replace only
        # the hardware discovery and lock ioctls, never access real MMC.
        sd = temp / "mock-sd.img"
        tail = b"SD-tail" * 219 + b"123"
        assert len(tail) == 1536
        sd.write_bytes(data + tail)
        cid = "0123456789abcdef0123456789abcdef"
        mock = source.replace("operation=$1", f"""
sd_device() {{
    sd_path={shlex.quote(str(sd))}
    sd_cid={cid}
    sd_sectors=8195
}}
unmounted() {{ :; }}
blockdev() {{ case "$1" in --getro) echo 1 ;; --setro|--setrw|--flushbufs) : ;; *) return 1 ;; esac; }}
PB626_SD_CID={cid}
PB626_SD_SECTORS=8195
operation=$1""", 1)
        script.write_text(mock)
        master, slave = os.openpty()
        try:
            def run(*args, ok=True):
                r = subprocess.run(["busybox", "sh", str(script), *args],
                                   stdin=slave, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=20)
                assert (r.returncode == 0) == ok, r.stderr
                return r.stdout
            digest = hashlib.sha256(tail).hexdigest()
            frame = run("backup-read-packed", "sd", "1")
            assert frame == f"\nPB626_DATA 1536 {digest} raw\n".encode() + tail + b"\nPB626_DATA_END\n"
            assert run("scan", "sd").splitlines()[-1] == f"BLOCK 1 {digest}".encode()
            assert run("verify", "sd").splitlines()[-1] == b"SHA256 " + hashlib.sha256(data + tail).hexdigest().encode()
            run("backup-read", "sd", "2", ok=False)
        finally:
            os.close(master)
            os.close(slave)
        new = bytes(1536)
        transfer(script, ["write", "sd", "1", "raw", str(len(new)), "0" * 64], new, success=False)
        assert sd.read_bytes() == data + tail
        result=transfer(script, ["write", "sd", "1", "raw", str(len(new)), hashlib.sha256(new).hexdigest()], new)
        assert result==f"PB626_WRITTEN 1 {hashlib.sha256(new).hexdigest()}\n".encode(),result
        assert sd.read_bytes() == data + new
        script.write_text(mock.replace(f"PB626_SD_CID={cid}", "PB626_SD_CID=wrong"))
        bad = subprocess.run(["busybox", "sh", str(script), "scan", "sd"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        assert bad.returncode != 0 and b"SD CID changed" in bad.stderr


def direct_fixture():
    source=Path(__file__).with_name("pb626-install-direct.sh").read_text()
    with tempfile.TemporaryDirectory() as directory:
        temp=Path(directory)
        image=temp/"disk"; image.write_bytes(bytes(128*512))
        part=temp/"part"; part.write_bytes(bytes(4194304))
        # Replace only hardware identity and block ioctls with a file-backed
        # fixture. The actual extent, receive, decode, write and readback run.
        source=source.replace("D=/dev/mmcblk2\n","D="+shlex.quote(str(image))+"\n",1)
        source=source.replace("P=/dev/mmcblk2p1\n","P="+shlex.quote(str(part))+"\n",1)
        source=source.replace("/run/pb626-install.XXXXXX",str(temp/"work.XXXXXX"))
        source=source.replace("operation=$1; cid=$2;",'identity() { :; }\nlock() { :; }\nblockdev() { :; }\noperation=$1; cid=$2;',1)
        script=temp/"direct.sh"; script.write_text(source)
        cid="a"*32
        env=dict(os.environ,PB626_TCP="1")
        def run(args,payload=b"",ok=True):
            result=subprocess.run(["busybox","sh",str(script),*args],input=payload,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,timeout=20)
            assert (result.returncode==0)==ok,result.stdout
            return result.stdout
        data=b"z"*512
        digest=hashlib.sha256(data).hexdigest()
        assert run(["chunk-hash",cid,"kernel","0","512"])==b"BLOCK 0 "+hashlib.sha256(bytes(512)).hexdigest().encode()+b"\n"
        run(["write",cid,"kernel","0","raw","512","0"*64,"512"],data,False)
        assert image.read_bytes()==bytes(128*512)
        assert b"PB626_WRITTEN" in run(["write",cid,"kernel","0","raw","512",digest,"512"],data)
        assert run(["chunk-hash",cid,"kernel","0","512"])==f"BLOCK 0 {digest}\n".encode()
        assert image.read_bytes()[80*512:81*512]==data
        for kind,index,length in (("kernel","3","512"),("rootfs","1741","4194304"),("spl","1","24576"),("kernel","0","513")):
            run(["chunk-hash",cid,kind,index,length],ok=False)
        # An unauthorized candidate is rejected even if header/length match.
        run(["write",cid,"spl-candidate","0","raw","24576","0"*64,"24576"],bytes(24576),False)

if __name__ == "__main__":
    main()
    direct_fixture()
