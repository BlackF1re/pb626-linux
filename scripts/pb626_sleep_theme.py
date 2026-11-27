#!/usr/bin/env python3
"""Extract the owner's stock sleep bitmaps offline; never redistribute them."""
import argparse
import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

P8_START = 275456 * 512
P8_SIZE = 500736 * 512
THEME_SHA256 = "f0288d4078084db0fe704efec5572152b0093982615e575333f7788c004d5b64"
BITMAPS = (
    ("sleep-portrait.pb", 0xADF71, 5160, (758, 1024, 0x8004, 380),
     "5d29e88e4209e7740a4acf7b9a77eb6097df23a6c3bd896168e4788c715223d8"),
    ("sleep-landscape.pb", 0xAF399, 5023, (1024, 758, 0x8004, 512),
     "ac2519eeb2d46aef1e5c724ad8ace66174f4a7fb9432b5bb67ac798facad2d33"),
)

def decode_theme(theme):
    if hashlib.sha256(theme).hexdigest() != THEME_SHA256:
        raise ValueError("Unsupported Line.pbt: expected verified stock 5.20.1157")
    images = {}
    for name, offset, length, header, digest in BITMAPS:
        raw = zlib.decompress(theme[offset:offset + length])
        w, h, _, stride = header
        if (len(raw) != 8 + (stride + (w + 7)//8)*h or
                struct.unpack_from("<4H", raw) != header or
                hashlib.sha256(raw).hexdigest() != digest):
            raise ValueError("Invalid stock sleep bitmap: " + name)
        images[name] = raw
    return images

def install_sleep_theme(source, destination, theme=None):
    """Read only the owner's regular-file backup; no mounts or block devices."""
    if theme is None:
        with tempfile.TemporaryDirectory(prefix="pb626-theme-") as work:
            partition = Path(work) / "p8.ext2"
            private_theme = Path(work) / "Line.pbt"
            with Path(source).open("rb") as inp, partition.open("wb") as out:
                inp.seek(P8_START)
                remaining = P8_SIZE
                while remaining:
                    data = inp.read(min(remaining, 8 * 1024 * 1024))
                    if not data:
                        raise ValueError("Short stock p8 read")
                    out.write(data)
                    remaining -= len(data)
            subprocess.run(["debugfs", "-R", "dump /themes/Line.pbt " + str(private_theme),
                            str(partition)], check=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE)
            if not private_theme.is_file():
                raise ValueError("Stock p8 theme missing; supply --sleep-theme")
            images = decode_theme(private_theme.read_bytes())
    else:
        images = decode_theme(Path(theme).read_bytes())
    destination.mkdir(parents=True, exist_ok=True)
    for name, raw in images.items():
        path = destination / name
        path.write_bytes(raw)
        path.chmod(0o644)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("theme", type=Path, help="Original Line.pbt from the owner's backup")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if not args.theme.is_file() or args.theme.stat().st_size != 770198:
        parser.error("Expected the verified 770198-byte Line.pbt")
    install_sleep_theme(None, args.destination, args.theme)
