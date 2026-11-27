#!/usr/bin/env python3
"""Host-side direct-install contract tests (no hardware writes)."""
import gzip
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("direct", ROOT/"scripts/installer/install-direct.py")
direct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(direct)

class DirectInstallTests(unittest.TestCase):
    def test_extent(self):
        self.assertEqual(direct.P1_BYTES, 7301234688)
        self.assertEqual(divmod(direct.P1_BYTES, direct.CHUNK), (1740,3145728))

    def test_stream_exact(self):
        data = b'a'*(direct.CHUNK+512)
        stream = gzip.GzipFile(fileobj=io.BytesIO(gzip.compress(data)))
        blocks = list(direct.image_blocks(stream, len(data)))
        self.assertEqual([i for i,b in blocks], [0,1])
        self.assertEqual(b''.join(b for i,b in blocks), data)
        for bad in (data[:-1], data+b'x'):
            with self.assertRaises(RuntimeError):
                list(direct.image_blocks(io.BytesIO(bad), len(data)))

    def test_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'SHA256SUMS'
            h = '0'*64
            p.write_text(h+'  ./file\n')
            self.assertEqual(direct.manifest(p), {'file':h})
            for bad in ('../file','/file','./file\n'+h+'  file'):
                p.write_text(h+'  '+bad+'\n')
                with self.assertRaises(RuntimeError):
                    direct.manifest(p)

    def test_write_frame(self):
        class Mock:
            def run(self, cmd, payload, timeout):
                self.cmd, self.payload = cmd, payload
                return ['PB626_WRITTEN']
        mock = Mock()
        data = b'\0'*4096
        direct.send_block(mock, 'a'*32, 'kernel', 0, data)
        self.assertEqual(gzip.decompress(mock.payload), data)
        self.assertIn(' write '+'a'*32+' kernel 0 gzip ', mock.cmd)
        self.assertTrue(mock.cmd.endswith(direct.sha(data)+' 4096'))

    def test_no_echo_marker(self):
        class Serial:
            def write(self, data):
                self.last = data
                return len(data)
            def flush(self): pass
        class Mock(direct.Recovery):
            def __init__(self):
                self.s = Serial()
                self.rows = None
            def line(self, deadline):
                if self.rows is None:
                    cmd = self.s.last.decode()
                    marker = cmd.split('PBEND_',1)[1].split('=',1)[0]
                    self.rows = iter(['echo PBEND_'+marker+'=%s','PBEND_'+marker+'=0'])
                return next(self.rows)
        self.assertEqual(len(Mock().run('true')),1)

if __name__ == '__main__':
    unittest.main()
