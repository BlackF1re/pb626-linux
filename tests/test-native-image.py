#!/usr/bin/env python3
"""Small regular-file tests; no block device or 8GB fixture required."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

p=Path(__file__).resolve().parents[1]/"scripts/build-native-image.py"
spec=importlib.util.spec_from_file_location("builder",p)
b=importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class NativeImage(unittest.TestCase):
    def test_overlay(self):
        with tempfile.TemporaryDirectory() as d:
            image=Path(d)/"image"
            source=Path(d)/"source"
            image.write_bytes(b"a"*32)
            source.write_bytes(b"b"*4)
            b.overlay(image,source,8,4)
            self.assertEqual(image.read_bytes(),b"a"*8+b"b"*4+b"a"*20)
            with self.assertRaises(SystemExit):
                b.overlay(image,source,30,4)
    def test_raw_crc(self):
        payload=b"test"
        h=bytearray(64)
        struct.pack_into(">7I",h,0,0x27051956,0,0,len(payload),0x40008000,0x40008000,zlib.crc32(payload))
        struct.pack_into(">I",h,4,zlib.crc32(h))
        raw=bytes(h)+payload+bytes(512-64-len(payload))
        b.validate_raw(raw)
        with self.assertRaises(SystemExit):
            b.validate_raw(raw[:64]+b"fail"+raw[68:])
    def test_root_password(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            (root/"etc").mkdir()
            shadow=root/"etc/shadow"
            shadow.write_text("root:!:0:0:99999:7:::\nreader:!:0:0:99999:7:::\n")
            h="$6$salt$"+"a"*86
            b.set_root_password(root,h)
            self.assertTrue(shadow.read_text().startswith("root:"+h+":"))
            self.assertIn("reader:!:",shadow.read_text())
            self.assertEqual(shadow.stat().st_mode & 0o777,0o600)
            for invalid in ("", "plaintext", "$6$salt$abc", h+":bad"):
                with self.assertRaises(SystemExit):
                    b.set_root_password(root,invalid)
    def test_regular(self):
        with self.assertRaises(SystemExit):
            b.regular(Path("/dev/null"))
if __name__=="__main__":
    unittest.main()
