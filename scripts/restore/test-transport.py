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


if __name__ == "__main__":
    main()
