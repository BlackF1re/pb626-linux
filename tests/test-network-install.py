#!/usr/bin/env python3
import importlib
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"scripts/installer"))
d=importlib.import_module("install-direct")
sys.path.insert(0,str(ROOT/"scripts"))
b=importlib.import_module("build-rootfs-bmap")

class Tests(unittest.TestCase):
    def test_sparse_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/"image"
            with p.open("wb") as f: f.truncate(64*1024*1024)
            subprocess.check_call(["mke2fs","-q","-F","-t","ext4","-b","4096",
                                   "-E","lazy_itable_init=0,lazy_journal_init=0",str(p)])
            m=b.build_map(p)
            self.assertEqual(m["version"],2)
            self.assertEqual(set(m["sha256"]),{str(i) for i in m["mapped"]})
            self.assertIn(0,m["mapped"])
            self.assertLess(len(m["mapped"]),16)
            target=Path(tmp)/"dirty"
            with target.open("wb") as f:
                for _ in range(16): f.write(b"x"*d.CHUNK)
            with p.open("rb") as src,target.open("r+b") as dst:
                for i in m["mapped"]:
                    src.seek(i*d.CHUNK); dst.seek(i*d.CHUNK)
                    dst.write(src.read(d.CHUNK))
            subprocess.check_call(["e2fsck","-fn",str(target)])
    def test_map_validation(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/"map.json"
            m={"version":1,"image_bytes":d.CHUNK*3,"chunk_bytes":d.CHUNK,"mapped":[0,2]}
            p.write_text(json.dumps(m))
            self.assertEqual(d.mapped_chunks(p,d.CHUNK*3),{0,2})
            for bad in ([1,2],[0,0],[0,3],[0,True],[0,-1],[0,2,1]):
                m["mapped"]=bad
                p.write_text(json.dumps(m))
                with self.assertRaises(RuntimeError):
                    d.mapped_chunks(p,d.CHUNK*3)
    def test_timeout_names_command(self):
        from unittest.mock import patch
        r=d.EthernetRecovery(configure=False)
        with patch.object(d.socket,"socket",side_effect=TimeoutError("timed out")):
            with self.assertRaisesRegex(d.TransportInterrupted,"dump-info emmc: timed out"):
                r.lines("dump-info","emmc")
    def test_tcp(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp)
            script=tmp/"fixture.sh"
            script.write_text("set -eu\ncase \"$1\" in\nhello) echo PB626-NCM-1;;\ntest) head -c 4194304 >\""+str(tmp/"payload")+"\"; test \"$(wc -c <'"+str(tmp/"payload")+"')\" = 4194304; echo TRANSFER_OK;;\n*) exit 9;;\nesac\n")
            with socket.socket() as s:
                s.bind(("127.0.0.1",0)); port=s.getsockname()[1]
            executable=tmp/"netd"
            subprocess.check_call(["gcc","-O2","-Wall","-Wextra","-Werror",
                '-DPB626_NET_ADDR="127.0.0.1"','-DPB626_NET_PEER="127.0.0.1"',
                '-DPB626_NET_DEV=""','-DPB626_NET_PORT='+str(port),
                '-DPB626_DISPATCH="'+str(script)+'"',
                str(ROOT/"scripts/restore/pb626-netd.c"),"-o",str(executable)])
            proc=subprocess.Popen([str(executable)])
            try:
                r=d.EthernetRecovery(configure=False,address="127.0.0.1",port=port)
                for _ in range(100):
                    try:
                        self.assertEqual(r.lines("hello"),["PB626-NCM-1"]); break
                    except OSError: time.sleep(.02)
                else: self.fail("TCP fixture not ready")
                data=os.urandom(d.CHUNK)
                self.assertEqual(r.lines("test",d.sha(data),payload=data),["TRANSFER_OK"])
                self.assertEqual((tmp/"payload").read_bytes(),data)
                with self.assertRaises(RuntimeError): r.lines("invalid")
            finally:
                proc.terminate(); proc.wait(timeout=5)
if __name__=="__main__": unittest.main()
