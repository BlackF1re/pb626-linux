#!/usr/bin/env python3
"""Generate matching Matchbox decoration geometry and monochrome PNG buttons."""
import argparse
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zlib

BASE = Path(__file__).resolve().parents[1] / "display/matchbox/PB626/theme.xml"


def png_chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))


def button_png(width, height, action):
    # Keep the glyph centered with a generous blank touch target around it.
    cx, cy = width // 2, height // 2
    radius = max(6, min(width, height) // 4)
    stroke = max(1, width // 16)
    rows = []
    for y in range(height):
        row = bytearray([0])  # PNG filter: None
        for x in range(width):
            dx, dy = x - cx, y - cy
            inside = abs(dx) <= radius and abs(dy) <= radius
            if action == "close":
                ink = inside and (abs(dx - dy) < stroke or abs(dx + dy) < stroke)
            else:
                ink = inside and any(abs(dy - line) < stroke
                                     for line in (-radius, 0, radius))
            value = 0 if ink else 255
            row.extend((value, value, value, 255))
        rows.append(row)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
            + png_chunk(b"IDAT", zlib.compress(b"".join(rows)))
            + png_chunk(b"IEND", b""))


def generate(root, height):
    tree = ET.parse(BASE)
    theme = tree.getroot()
    theme.set("name", f"PB626-{height}")
    theme.find("font[@id='titlefont']").set("def", f"Sans bold {height // 2}px")
    content = height - 2
    width = height - 8
    for frame_id in ("main", "dialog"):
        frame = theme.find(f"frame[@id='{frame_id}']")
        frame.set("height", str(height))
        line = frame.findall("layer")[1]
        line.set("y", str(content))
        label = frame.find("layer[@type='label']")
        label.set("h", str(content))
        label.set("x", str(width + 10 if frame_id == "main" else 6))
        label.set("w", f"100%-{2 * width + 20 if frame_id == 'main' else width + 16}")
        for button in frame.findall("button"):
            button.set("w", str(width))
            button.set("h", str(content))
            if button.get("action") == "close":
                button.set("x", f"100%-{width + 4}")
    target = root / f"PB626-{height}/matchbox"
    target.mkdir(parents=True, exist_ok=True)
    tree.write(target / "theme.xml", encoding="utf-8", xml_declaration=True)
    for action in ("close", "menu"):
        (target / f"{action}.png").write_bytes(button_png(width, content, action))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    for size in (32, 48, 56, 64):
        generate(args.output, size)
