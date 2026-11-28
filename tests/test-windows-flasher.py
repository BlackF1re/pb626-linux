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
dump=importlib.import_module("dump-network")

def fixture_dtb(rndis=False, ram=0x10000000, initrd=123):
    import struct
    pack=lambda *v: struct.pack(">"+"I"*len(v),*v)
    pad=lambda b: b+b"\0"*((-len(b))%4)
    names=b""
    def prop(name,value):
        nonlocal names
        pos=len(names)
        names+=name.encode()+b"\0"
        return pack(3,len(value),pos)+pad(value)
    def node(name,body):
        return pack(1)+pad(name.encode()+b"\0")+body+pack(2)
    body=node("",node("memory@40000000",prop("reg",pack(0x40000000,ram)))+
        node("soc",node("mmc@1c11000",prop("status",b"okay\0"))+
                   node("mmc@1c0f000",prop("status",b"disabled\0")))+
        node("chosen",prop("pb626,emmc-backup",b"")+
             prop("linux,initrd-start",pack(0x45000000))+
             prop("linux,initrd-end",pack(0x45000000+initrd))+
             (prop("pb626,windows-rndis",b"") if rndis else b"")))+pack(9)
    off=56
    return pack(0xd00dfeed,off+len(body)+len(names),off,off+len(body),40,17,16,0,len(names),len(body))+bytes(16)+body+names

class Tests(unittest.TestCase):
    def test_binary_dtb(self):
        for rndis in (False,True):
            tree=fixture_dtb(rndis)
            profile="rndis" if rndis else "ncm"
            fel.validate_dtb(tree,profile,123)
            for bad,p,n in ((tree,"ncm" if rndis else "rndis",123),
                            (tree,profile,124),(tree[:-1],profile,123),
                            (fixture_dtb(rndis,ram=0x20000000),profile,123)):
                with self.assertRaises(RuntimeError):
                    fel.validate_dtb(bad,p,n)

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
    def test_lost_write_ack(self):
        class Device:
            media=b"old"
            writes=0
            def run(self,cmd,payload=None,timeout=120):
                if " chunk-hash " in cmd:
                    return ["BLOCK 0 "+direct.sha(self.media)]
                self.writes+=1
                self.media=b"new"
                raise direct.TransportInterrupted("ACK lost")
        with tempfile.TemporaryDirectory() as directory:
            j=Path(directory)/"session.txt"
            dev=Device()
            with self.assertRaises(direct.TransportInterrupted):
                direct.write_if_different(dev,"a"*32,"kernel",0,b"new",j)
            self.assertEqual(j.read_text().splitlines()[0],"writing")
            direct.journal(j,"preflight")
            self.assertEqual(j.read_text().splitlines()[0],"writing")
            self.assertFalse(direct.write_if_different(dev,"a"*32,"kernel",0,b"new",j))
            self.assertEqual(dev.writes,1)
    def test_bad_chunk_response_never_writes(self):
        class Device:
            def run(self,cmd,*args,**kwargs):
                self.assert_cmd=cmd
                if " chunk-hash " not in cmd:
                    raise AssertionError("unexpected write")
                return ["BLOCK 1 "+"a"*64]
        with self.assertRaises(RuntimeError):
            direct.write_if_different(Device(),"a"*32,"rootfs",0,b"data")
    def test_resume_identity_pinned(self):
        with tempfile.TemporaryDirectory() as directory:
            j=Path(directory)/"session.txt"
            direct.pin_session(j,{"cid":"a","input":"b"})
            direct.pin_session(j,{"cid":"a","input":"b"})
            for changed in ({"cid":"c","input":"b"},{"cid":"a","input":"c"}):
                with self.assertRaises(RuntimeError): direct.pin_session(j,changed)
    def test_resume_backup_no_retransfer_verified_chunks(self):
        blocks=[b"a"*512,b"b"*512,b"c"*128]
        data=b"".join(blocks)
        with tempfile.TemporaryDirectory() as directory:
            partial=Path(directory)/"image.partial"
            finished=Path(directory)/"image"
            partial.write_bytes(blocks[0]+b"x"*512+b"torn")
            with patch.object(dump,"CHUNK",512), patch.object(dump,"scan",return_value={i:direct.sha(b) for i,b in enumerate(blocks)}), patch.object(dump,"digest",return_value=direct.sha(data)), patch.object(dump,"read_block",side_effect=lambda r,c,s,reg,i,n:blocks[i]) as read:
                self.assertEqual(dump.backup_region(None,"a",3,"user",len(data),partial,finished),direct.sha(data))
                self.assertEqual([call.args[4] for call in read.call_args_list],[1,2])
            self.assertEqual(finished.read_bytes(),data)
            self.assertFalse(partial.exists())
    def test_backup_interruption_keeps_verified_prefix(self):
        blocks=[b"a"*512,b"b"*512]
        with tempfile.TemporaryDirectory() as directory:
            partial=Path(directory)/"image.partial"
            finished=Path(directory)/"image"
            with patch.object(dump,"CHUNK",512), patch.object(dump,"read_block",side_effect=[blocks[0],direct.TransportInterrupted("disconnected")]):
                with self.assertRaises(direct.TransportInterrupted):
                    dump.backup_region(None,"a",2,"user",1024,partial,finished)
            self.assertEqual(partial.read_bytes(),blocks[0])
            self.assertFalse(finished.exists())
    def test_verified_source_chunk_map(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"dump"
            path.write_bytes(b"a"*512+b"b"*16)
            with patch.object(dump,"CHUNK",512):
                self.assertEqual(dump.verified_source(path,528,direct.filehash(path)),
                                 {0:direct.sha(b"a"*512),1:direct.sha(b"b"*16)})
                with self.assertRaises(RuntimeError):
                    dump.verified_source(path,528,"0"*64)
    def test_restore_requires_readback_ack(self):
        class Device:
            def lines(self,*args,**kwargs): return []
        with self.assertRaises(RuntimeError):
            dump.write_block(Device(),"a",1,"user",0,b"data")
if __name__=="__main__": unittest.main()
