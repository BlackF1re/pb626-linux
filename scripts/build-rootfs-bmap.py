#!/usr/bin/env python3
"""Map 4 MiB chunks containing allocated ext4 blocks. Never omit metadata.

dumpe2fs enumerates filesystem-free blocks, not merely zero bytes or host
file holes. A chunk is omitted only if every block is free AND the source
chunk is zero. The target's free space need not be zero (not a secure erase).
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

CHUNK = 4194304

def build_map(image):
    env = dict(os.environ, LC_ALL="C")
    info = subprocess.check_output(["dumpe2fs", str(image)], env=env,
                                   text=True, stderr=subprocess.DEVNULL)
    def field(key):
        match = re.search(r"^"+key+r":\s*(\d+)\s*$", info, re.M)
        if not match:
            raise ValueError("Missing ext4 field "+key)
        return int(match[1])
    block = field("Block size")
    total = field("Block count")
    free_count = field("Free blocks")
    size = image.stat().st_size
    if block != 4096 or total*block != size:
        raise ValueError("Unexpected ext4 geometry")
    ranges = []
    for line in re.findall(r"^ +Free blocks:[ \t]*(.*)$", info, re.M):
        for item in line.strip().split(","):
            item = item.strip()
            if not item:
                continue
            match = re.fullmatch(r"(\d+)(?:-(\d+))?", item)
            if not match:
                raise ValueError("Malformed free range: "+item)
            a, b = int(match[1]), int(match[2] or match[1])
            if not 0 <= a <= b < total:
                raise ValueError("Out of bounds ext4 free range")
            ranges.append((a,b+1))
    merged = []
    for a,b in sorted(ranges):
        if merged and a < merged[-1][1]:
            raise ValueError("Overlapping ext4 free ranges")
        if merged and a == merged[-1][1]:
            merged[-1] = (merged[-1][0], b)
        else:
            merged.append((a,b))
    if sum(b-a for a,b in merged) != free_count:
        raise ValueError("Ext4 free-block accounting mismatch")
    mapped = []
    cursor = 0
    with image.open("rb") as f:
        for idx, start in enumerate(range(0,size,CHUNK)):
            end = min(start+CHUNK,size)
            a,b = start//block,end//block
            while cursor < len(merged) and merged[cursor][1] <= a:
                cursor += 1
            free = cursor < len(merged) and merged[cursor][0] <= a and merged[cursor][1] >= b
            if free and idx != 0:
                f.seek(start)
                data = f.read(end-start)
                if data == bytes(end-start):
                    continue
            mapped.append(idx)
    return {"version":1,"image_bytes":size,"chunk_bytes":CHUNK,"mapped":mapped}

if __name__ == "__main__":
    result = build_map(Path(sys.argv[1]))
    Path(sys.argv[2]).write_text(json.dumps(result,separators=(",",":"))+"\n")
    print("Allocated/required ext4 chunks: %d of %d" %
          (len(result["mapped"]), (result["image_bytes"]+CHUNK-1)//CHUNK))
