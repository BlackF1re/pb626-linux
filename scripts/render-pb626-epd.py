"""Generate the RESET and monochrome DU streams for the ELAN RAM diagnostic."""

import argparse
from gzip import open as gzip_open
from itertools import groupby
from pathlib import Path
import struct
import zlib

from PIL import Image, ImageOps


SOURCES, GATES = 1024, 758
SCAN_WIDTH, SCAN_HEIGHT = 304, 767
SOURCE_PINS = (3, 4, 5, 6, 7, 10, 11, 12)
S_LE, G_MODE, S_OE, S_SP, G_CLK, G_SP = (
    1 << bit for bit in (13, 15, 20, 21, 22, 23)
)
BASE = G_MODE | G_SP
IDLE = BASE | S_SP
SOURCE_START = 40
GATE_HIGH_CLOCKS = 85
HEADER_SIZE = 64
LUT_SIZE = 64


def read_pointer(waveform, offset, *, checksum=True):
    digits = waveform[offset:offset + 3]
    address = int.from_bytes(digits, "little")
    if (len(digits) != 3 or not 0 < address < len(waveform)
            or (checksum and waveform[offset + 3] != (sum(digits) & 255))):
        raise ValueError("invalid WBF table pointer")
    return address


def read_phases(waveform, mode, interval):
    modes = read_pointer(waveform, 0x20, checksum=False)
    table = read_pointer(waveform, modes + mode * 4)
    start = read_pointer(waveform, table + interval * 4)
    offset = start
    expanded = bytearray()
    repeat_mode = True
    while waveform[offset] != 255:
        token = waveform[offset]
        offset += 1
        if token == 252:
            repeat_mode = not repeat_mode
            continue
        count = waveform[offset] + 1 if repeat_mode else 1
        offset += int(repeat_mode)
        expanded.extend(bytes([token]) * count)
        if len(expanded) > 256 * LUT_SIZE:
            raise ValueError("WBF waveform exceeds 256 phases")
    if not expanded or len(expanded) % LUT_SIZE:
        raise ValueError("invalid WBF phase data length")
    if waveform[offset + 1] != (sum(waveform[start:offset + 1]) & 255):
        raise ValueError("invalid WBF phase checksum")
    return [expanded[i:i + LUT_SIZE] for i in range(0, len(expanded), LUT_SIZE)]


def waveform_runs(path, temperature):
    waveform = path.read_bytes()
    if (len(waveform) < 0x32 or len(waveform) != int.from_bytes(waveform[4:8], "little")
            or zlib.crc32(bytes(4) + waveform[4:]) != int.from_bytes(waveform[:4], "little")
            or waveform[0x10] != 0x23 or waveform[0x28:0x2a] != b"\xff\xfc"):
        raise ValueError("expected a valid factory WBF with mode version 0x23")
    bounds = waveform[0x30:0x32 + waveform[0x26]]
    interval = next((i for i, (low, high) in enumerate(zip(bounds, bounds[1:]))
                     if low * 1000 <= temperature < high * 1000), None)
    if interval is None:
        raise ValueError("temperature is outside the WBF range")

    reset = read_phases(waveform, 0, interval)
    if any(lut[0] not in (0, 0x55, 0xaa) or lut != lut[:1] * LUT_SIZE for lut in reset):
        raise ValueError("expected a uniform factory RESET waveform")

    du = read_phases(waveform, 1, interval)
    # A white source is level 15. Target levels 0 and 15 are black and white.
    black = [(lut[3] >> 6) & 3 for lut in du]
    if any(lut[63] >> 6 for lut in du) or 3 in black or not any(black):
        raise ValueError("expected a DU waveform from a white screen")
    reset_runs = [(lut[0] & 3, len(list(group))) for lut, group in
                  groupby(reset, key=lambda lut: lut[:1])]
    du_runs = [(value, len(list(group))) for value, group in groupby(black)]
    return reset_runs, du_runs


def scanline(*segments):
    return b"".join(struct.pack("<I", word) * clocks for clocks, word in segments)


def source_word(data):
    return sum(1 << pin for bit, pin in enumerate(SOURCE_PINS) if data & (1 << bit))


def frame(signal, repeats, image_rows=None):
    # ED060XD4 scan timing and pin mapping from Megi's fixed-panel driver.
    third = SCAN_WIDTH // 3
    start = scanline((20, IDLE), (2 * third, IDLE | G_CLK),
                     (SCAN_WIDTH - 20 - 2 * third, IDLE))
    start += scanline((third, IDLE | G_CLK), (third, G_MODE | S_SP | G_CLK),
                      (SCAN_WIDTH - 2 * third, G_MODE | S_SP))
    start += scanline((third, G_MODE | S_SP | G_CLK), (third, IDLE | G_CLK),
                      (SCAN_WIDTH - 2 * third, IDLE))
    start += scanline((2 * third, IDLE | G_CLK), (SCAN_WIDTH - 2 * third, IDLE)) * 3

    def data_row(*, first=False, last=False):
        oe = 0 if first else S_OE
        latch = 0 if first else S_LE
        pins = BASE | oe | (S_SP if last else source_word(signal * 0x55))
        return scanline((22, IDLE), (6, IDLE | latch), (2, IDLE | latch | oe),
                        (8, IDLE | oe), (2, IDLE | oe | G_CLK),
                        (GATE_HIGH_CLOCKS, pins | G_CLK),
                        (SOURCES // 4 - GATE_HIGH_CLOCKS, pins), (8, IDLE | oe))

    header = struct.pack("<4I", 0x46445045, 0, 0, repeats - 1).ljust(HEADER_SIZE, b"\0")
    end = scanline((SCAN_WIDTH, G_SP | S_SP)) * 2
    raw = bytearray(header + start + data_row(first=True) + data_row() * (GATES - 1)
                    + data_row(last=True) + end)
    assert len(raw) == HEADER_SIZE + SCAN_WIDTH * SCAN_HEIGHT * 4
    if image_rows is not None and signal:
        # The first pixel of each group goes on D7:D6, the fourth on D1:D0.
        words = [source_word(sum(signal << (2 * (3 - i)) for i in range(4) if mask & (1 << i)))
                 for mask in range(16)]
        for y, row in enumerate(image_rows):
            pins = BASE | (S_OE if y else 0)
            packed = [pins | words[mask] | (G_CLK if x < GATE_HIGH_CLOCKS else 0)
                      for x, mask in enumerate(row)]
            offset = HEADER_SIZE + ((6 + y) * SCAN_WIDTH + SOURCE_START) * 4
            struct.pack_into("<256I", raw, offset, *packed)
    return raw


def prepare_image(path):
    with Image.open(path) as image:
        rgba = image.convert("RGBA")
    white = Image.new("RGBA", rgba.size, "white")
    white.alpha_composite(rgba)
    image = ImageOps.contain(ImageOps.autocontrast(white.convert("L")), (710, 958))
    canvas = Image.new("L", (GATES, SOURCES), 255)
    canvas.paste(image, ((GATES - image.width) // 2, (SOURCES - image.height) // 2))
    pixels = canvas.transpose(Image.Transpose.ROTATE_90).point(lambda p: int(p < 128)).tobytes()
    return [bytes(sum(pixels[x + bit] << bit for bit in range(4))
                  for x in range(y * SOURCES, (y + 1) * SOURCES, 4)) for y in range(GATES)]


def write_stream(path, runs, image_rows=None, *, padding=0):
    with gzip_open(path, "wb") as output:
        for signal, count in runs + [(0, 1)] * padding:
            data = frame(signal, count, image_rows)
            output.write(struct.pack(">II", int.from_bytes(b"Vhdr", "little"), len(data)))
            output.write(data)
    print(f"{path}: {len(runs)} mmap buffers, {sum(count for _, count in runs)} scans")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("waveform", type=Path, help="factory default.wbf from the offline dump")
    parser.add_argument("temperature_mc", type=int, help="panel temperature in millidegrees Celsius")
    parser.add_argument("image", type=Path, help="image to show in portrait orientation")
    parser.add_argument("prefix", type=Path, help="output prefix for -reset.vhdr.gz and -image.vhdr.gz")
    args = parser.parse_args()
    try:
        reset, du = waveform_runs(args.waveform, args.temperature_mc)
        image = prepare_image(args.image)
        # Extra neutral frames let v4l2-ctl finish streaming the reset even at EOF.
        write_stream(f"{args.prefix}-reset.vhdr.gz", reset, padding=4)
        write_stream(f"{args.prefix}-image.vhdr.gz", du, image)
    except (IndexError, OSError, ValueError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
