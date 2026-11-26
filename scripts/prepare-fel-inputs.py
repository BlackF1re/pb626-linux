#!/usr/bin/env python3
"""Prepare missing local FEL inputs; never overwrite existing inputs or touch devices.

The exact lab SPL is extracted from the author's historical distribution, not
from a new build. The host tool is rebuilt from the recovered lab sources and
needs hardware qualification. This command is an explicit opt-in.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import urllib.request

UBOOT_SHA = "ad00580889a797836b05ed8c718c11d5ccb014aa266707c4f41fa89d192fb87f"
SPL_SHA = "7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f"
ENTRY_SHA = "1a0044b4533ce91bb1f19f5fef9f1356242d3855cadd4087cc1c6a6ac22a21dd"
URL = "https://xff.cz/kernels/bootloaders/pb/uboot.bin"

def sha(data):
    return hashlib.sha256(data).hexdigest()

def require(ok, msg):
    if not ok:
        raise SystemExit(msg)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", type=Path, required=True, help="Verified same-run fel-host directory")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--uboot", type=Path, help="Original local uboot.bin instead of downloading")
    a = p.parse_args()
    manifest = dict((name, digest) for digest, name in
                    (line.split("  ", 1) for line in (a.host/"SHA256SUMS").read_text().splitlines()))
    # Existing trusted inputs are preferred. Read and validate all missing
    # sources before writing anything. Use exclusive creation (no overwrite).
    data = {}
    for name in ("direct-entry.bin", "sunxi-fel"):
        target = a.output/name
        if target.exists():
            if name == "direct-entry.bin":
                require(sha(target.read_bytes()) == ENTRY_SHA, "Unknown existing entry stub")
            continue
        content = (a.host/name).read_bytes()
        require(sha(content) == manifest.get(name), "Host manifest mismatch: "+name)
        if name == "direct-entry.bin":
            require(sha(content) == ENTRY_SHA, "Wrong entry stub")
        data[name] = content
    target = a.output/"pb626-spl.bin"
    if target.exists():
        require(sha(target.read_bytes()) == SPL_SHA, "Unknown existing SPL")
    else:
        if a.uboot:
            combined = a.uboot.read_bytes()
        else:
            # Bounded read; HTTPS with normal certificate validation.
            with urllib.request.urlopen(URL, timeout=30) as response:
                combined = response.read(284993)
        require(len(combined) == 284992 and sha(combined) == UBOOT_SHA,
                "Historical upstream U-Boot differs from lab copy; stop")
        spl = combined[:24576]
        require(sha(spl) == SPL_SHA, "Extracted SPL differs from lab copy")
        data["pb626-spl.bin"] = spl
    a.output.mkdir(parents=True, exist_ok=True)
    for name, content in data.items():
        dest = a.output/name
        with dest.open("xb") as fp:
            fp.write(content)
        if name == "sunxi-fel":
            dest.chmod(0o755)
        print("Prepared:", dest, sha(content))
    print("No device accessed. Use a cold FEL RAM recovery test before writing eMMC.")

if __name__ == "__main__":
    main()
