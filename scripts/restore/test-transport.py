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


if __name__ == "__main__":
    main()
