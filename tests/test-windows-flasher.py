#!/usr/bin/env python3
"""Exercise Windows FEL uploader without USB and verify packaged imports."""
import importlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
import sys
sys.path[:0]=[str(ROOT/"scripts/windows"),str(ROOT/"scripts/installer")]
fel=importlib.import_module("windows-fel")
direct=importlib.import_module("install-direct")

class Tests(unittest.TestCase):
    def test_chunks_and_readback(self):
        data=bytes(range(256))*260
        with tempfile.TemporaryDirectory() as directory:
            tmp=Path(directory)
            calls=[]
            def fake(exe,args,cwd,**kwargs):
                calls.append(args)
                (cwd/"readback.bin").write_bytes((cwd/"chunk.bin").read_bytes())
            with patch.object(fel,"invoke",fake):
                fel.upload(Path("fel.exe"),tmp,data,0x42000000,"kernel")
            self.assertEqual([(x[1],x[5]) for x in calls],[("0x42000000",65536),("0x42010000",1024)])
            calls.clear()
            def corrupt(exe,args,cwd,**kwargs):
                calls.append(args)
                (cwd/"readback.bin").write_bytes(b"bad")
            with patch.object(fel,"invoke",corrupt), self.assertRaises(RuntimeError):
                fel.upload(Path("fel.exe"),tmp,data,0x42000000,"kernel")
            self.assertEqual(len(calls),1)
    def test_wrong_soc(self):
        class Result:
            stdout=b"AWUSBFEX soc=00001651(A20)"
        with patch.object(fel,"invoke",return_value=Result()), self.assertRaises(RuntimeError):
            fel.probe(Path("fel.exe"),ROOT)
    def test_windows_source_bind(self):
        calls=[]
        class Sock:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def settimeout(self,t): pass
            def bind(self,address): calls.append(("bind",address))
            def connect(self,address): calls.append(("connect",address))
            def sendall(self,data): calls.append(("send",data))
            def shutdown(self,mode): pass
            def recv(self,n):
                if calls[-1][0]=="recv": return b""
                calls.append(("recv",n)); return b"PB626-NCM-1\n\nPB626_STATUS 0\n"
        with patch.object(direct.os,"name","nt"), patch.object(direct.socket,"socket",return_value=Sock()):
            direct.EthernetRecovery(windows=True)
        self.assertEqual(calls[:3],[("bind",("169.254.62.2",0)),("connect",("169.254.62.1",6262)),("send",b"PB626/1 hello\n")])
    def test_journal_before_write(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"session.txt"
            direct.journal(path,"preflight")
            self.assertEqual(path.read_text().splitlines()[0],"preflight")
            direct.journal(path,"writing","rootfs chunk 1")
            self.assertEqual(path.read_text().splitlines(),["writing","rootfs chunk 1"])
            direct.journal(path,"verified","firmware")
            self.assertEqual(path.read_text().splitlines(),["verified","firmware"])
    def test_recovery_identity_and_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            kit=Path(directory)
            (kit/"native").mkdir()
            (kit/"native/BUILD-COMMIT").write_text("a"*40)
            (kit/"candidate").mkdir()
            candidate=direct.candidate_path(kit)
            candidate.write_bytes(b"spl")
            expected="a"*40+" standard "+direct.filehash(candidate)
            class Mock:
                def __init__(self,identity,rows): self.identity=identity; self.rows=rows
                def lines(self,verb,timeout):
                    return [self.identity] if verb=="identity" else self.rows
            with self.assertRaises(RuntimeError):
                direct.check_windows_recovery(Mock("wrong",[]),kit)
            with self.assertRaises(RuntimeError):
                direct.check_windows_recovery(Mock(expected,[]),kit)
            self.assertEqual(direct.check_windows_recovery(Mock(expected,[]),kit,ready=False),[])
            rows=["CID="+"a"*32]
            self.assertEqual(direct.check_windows_recovery(Mock(expected,rows),kit),rows)
    def test_cancel_is_not_write(self):
        with patch("builtins.input",return_value="no"), self.assertRaises(direct.Cancelled):
            direct.confirm("Type FLASH: ","FLASH")
if __name__=="__main__": unittest.main()
