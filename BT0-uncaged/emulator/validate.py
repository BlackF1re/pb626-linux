#!/usr/bin/env python3
"""Execute SPL machine code on Cortex-A8 with an explicit A13 peripheral model.

This is a strict, incremental board model, not full-system emulation. Unknown
MMIO never returns a fabricated success. Full-boot probing reports the first
unmodelled access separately from the executable boot-contract tests.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from elftools.elf.elffile import ELFFile
from unicorn import Uc, UcError, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE, \
    UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE, UC_HOOK_MEM_INVALID, UC_MEM_READ, \
    UC_MEM_WRITE
from unicorn.arm_const import UC_CPU_ARM_CORTEX_A8, UC_ARM_REG_R0, \
    UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_R4, \
    UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8, \
    UC_ARM_REG_R9, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_CPSR

REFERENCE_SHA = "1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6"
ADC = 0x01c22800
PIO_GATE = 0x01c20068
PE_CFG = 0x01c20894
PE_DATA = 0x01c208a0
RTC_MAGIC = 0x01c20d28
TIMER0 = 0x01c20c18
RETURN = 0x7f00
KEEP = [UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
        UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_SP]

def require(ok, message):
    if not ok:
        raise AssertionError(message)

def check_header(data):
    require(len(data) == 24576 and data[4:12] == b"eGON.BT0", "SPL slot/header")
    expected, size = struct.unpack_from("<II", data, 12)
    require(size == len(data), "SPL header size")
    copy = bytearray(data)
    struct.pack_into("<I", copy, 12, 0x5f0a6c39)
    require(sum(struct.unpack("<6144I", copy)) & 0xffffffff == expected, "SPL checksum")

def symbols(path):
    with path.open("rb") as fh:
        elf = ELFFile(fh)
        require(elf["e_machine"] == "EM_ARM", "not ARM ELF")
        table = elf.get_section_by_name(".symtab")
        require(table is not None, "no ELF symbols")
        return {s.name: s["st_value"] for s in table.iter_symbols() if s.name}

class Board:
    """SRAM and the registers exercised by the early Menu and LED paths."""
    def __init__(self, image, samples=(), events=0, fel=False, rtc=0):
        self.uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        self.uc.ctl_set_cpu_model(UC_CPU_ARM_CORTEX_A8)
        self.uc.mem_map(0, 0x10000)
        self.uc.mem_write(0, image)
        if fel:
            self.uc.mem_write(8, b".FEL")
        self.uc.mem_map(0x01c20000, 0x3000)
        self.uc.mem_map(0xffff0000, 0x1000)
        self.samples = list(samples)
        self.events = events
        self.index = 0
        self.converting = False
        self.regs = {ADC: 0x0100016a, ADC+4: 0x12, ADC+8: 0, ADC+12: 0,
                     PIO_GATE: 0x10, PE_CFG: 0xa5a5a5af, PE_DATA: 0xffffffff,
                     RTC_MAGIC: rtc, TIMER0: 0xffffffff}
        self.writes = []
        self.timer_step = 0
        self.unsupported = None
        self.hit = None
        self.targets = {}
        self.uc.reg_write(UC_ARM_REG_CPSR, 0x600001d3)
        self.uc.reg_write(UC_ARM_REG_SP, 0x7e00)
        self.uc.reg_write(UC_ARM_REG_LR, 0xa2c0 if fel else 0xffff1234)
        for i, reg in enumerate(KEEP[:-1]):
            self.uc.reg_write(reg, 0x12340004+i)
        self.uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, self.mmio,
                         begin=0x01c20000, end=0x01c22fff)
        self.uc.hook_add(UC_HOOK_MEM_INVALID, self.invalid)
        self.uc.hook_add(UC_HOOK_CODE, self.code)

    def code(self, uc, address, size, data):
        if address in self.targets:
            self.hit = self.targets[address]
            uc.emu_stop()

    def invalid(self, uc, access, address, size, value, data):
        self.unsupported = {"address": hex(address), "access": access,
                            "size": size, "pc": hex(uc.reg_read(UC_ARM_REG_PC))}
        return False

    def mmio(self, uc, access, address, size, value, data):
        if address not in self.regs or size != 4:
            self.invalid(uc, access, address, size, value, data)
            uc.emu_stop()
            return
        if access == UC_MEM_READ:
            val = self.regs[address]
            if address == TIMER0:
                self.regs[address] = (val - self.timer_step) & 0xffffffff
            if address == ADC+8:
                val = (int(self.index < len(self.samples)) | self.events) if self.converting else 0
            elif address == ADC+12:
                require(self.converting and self.index < len(self.samples), "ADC read without sample")
                val = self.samples[self.index]
            uc.mem_write(address, struct.pack("<I", val))
        elif access == UC_MEM_WRITE:
            self.writes.append((address, value & 0xffffffff))
            if address == ADC:
                self.converting = value == 0x02002141
            elif address == ADC+8 and self.converting and value == 1:
                self.index += 1
            self.regs[address] = value & 0xffffffff

    def run(self, address, targets, budget=6000000, probe=False):
        self.hit = None
        self.unsupported = None
        self.targets = targets
        try:
            self.uc.emu_start(address, 0xffffffff, count=budget)
        except UcError:
            if not (probe and self.unsupported):
                raise
        if probe:
            return {"boundary": self.unsupported, "stop": self.hit,
                    "pc": hex(self.uc.reg_read(UC_ARM_REG_PC)),
                    "complete": self.hit == "kernel-entry"}
        require(self.unsupported is None, f"unmodelled access: {self.unsupported}")
        require(self.hit is not None, f"instruction budget exhausted at {self.uc.reg_read(UC_ARM_REG_PC):#x}")
        return self.hit

    def call(self, address, *args):
        for reg, value in zip((UC_ARM_REG_R0, UC_ARM_REG_R1,
                               UC_ARM_REG_R2, UC_ARM_REG_R3), args):
            self.uc.reg_write(reg, value)
        self.uc.reg_write(UC_ARM_REG_LR, RETURN)
        self.run(address, {RETURN: "return"}, budget=100000)
        return self.uc.reg_read(UC_ARM_REG_R0)

def scenarios():
    # Each branch of the existing Menu algorithm, including actual timeout
    # loops. No timeout counter is patched in either binary.
    yield "normal", [63]*5, 0, False, 1
    yield "boundary", [0,48,48,48,48], 0, False, 1
    yield "menu", [63,13,13,13,13], 0, False, 2
    yield "ambiguous", [63,63,47,63,63], 0, False, 2
    yield "event", [63]*5, 2, False, 2
    yield "no-event", [], 0, False, 1
    yield "partial", [63,63], 0, False, 3
    yield "fel-return", [63,13,13,13,13], 0, True, 2
    yield "fel-no-key", [63]*5, 0, True, 1

def menu_cases(image, save, report):
    result = {}
    # An armed deep resume must not change the first-stage Menu decision.
    for name, samples, events, fel, expected, rtc in (
        (name + suffix, samples, events, fel, expected, rtc)
        for name, samples, events, fel, expected in scenarios()
        for suffix, rtc in (("", 0), ("-resume-armed", 0x53555350))
    ):
        board = Board(image, samples, events, fel, rtc=rtc)
        initial = [board.uc.reg_read(r) for r in KEEP]
        cpsr = board.uc.reg_read(UC_ARM_REG_CPSR) & 0xff
        stop = board.run(0, {save & ~1: "native", 0x20: "rom-low",
                            0xffff0020: "rom-high", 0xa2c0: "fel-thunk"})
        words = struct.unpack("<10I", board.uc.mem_read(report, 40))
        require(words[0] == 0x36324250 and words[1] == expected, name+": report")
        require(words[2] == max(0,min(4,len(samples)-1)), name+": sample count")
        require(list(words[3:3+words[2]]) == samples[1:1+words[2]], name+": samples")
        require(words[8:10] == (0x0100016a,0x12), name+": saved ADC")
        require(board.regs[ADC] == 0x0100016a and board.regs[ADC+4] == 0x12, name+": ADC restore")
        require([board.uc.reg_read(r) for r in KEEP] == initial, name+": register restore")
        require(board.uc.reg_read(UC_ARM_REG_CPSR) & 0xff == cpsr, name+": CPSR restore")
        require((stop == "native") == (expected == 1), name+": branch")
        if fel and expected != 1:
            require(stop == "fel-thunk", name+": FEL return")
        if expected == 1:
            require(board.uc.reg_read(UC_ARM_REG_LR) == (0xa2c0 if fel else 0xffff1234), name+": LR")
        require(not any(a in (PE_CFG,PE_DATA,PIO_GATE,RTC_MAGIC) for a,_ in board.writes),
                name+": early GPIO or RTC interference")
        require(board.regs[RTC_MAGIC] == rtc, name+": RTC marker changed before FEL decision")
        result[name] = {"target": stop, "reason": words[1], "samples": list(words[3:3+words[2]])}
    return result

def led_cases(image, sym):
    def states(board):
        return [int(not(v & 0x100)) for a,v in board.writes if a == PE_DATA]

    start = sym["pb626_led_boot_start"]
    tick = sym["pb626_led_boot_tick"]
    handoff = sym["spl_board_prepare_for_boot"]
    for mode, rtc in ((True,0),(False,0x53555350)):
        board = Board(image, fel=mode, rtc=rtc)
        board.call(start, 0)
        board.call(handoff)
        require(not board.writes, "LED touched FEL or retained DRAM")

    board = Board(image)
    origin = 0xffff0000
    board.call(start, origin)
    require(states(board) == [1], "initial LED")
    for i, ms in enumerate((100,200,300,400)):
        board.call(tick, (origin+ms*24000-1)&0xffffffff)
        require(len(states(board)) == i+1, "premature edge")
        board.call(tick, (origin+ms*24000)&0xffffffff)
        require(states(board) == [1,0,1,0,1][:i+2], "edge timing")
    require(board.regs[PE_CFG] == 0xa5a5a5a1, "neighbor mux altered")
    require(board.regs[PE_DATA] == 0xfffffeff, "neighbor output altered")
    require(board.regs[PIO_GATE] == 0x30, "neighbor clock altered")
    board.call(handoff)
    require(states(board) == [1,0,1,0,1], "handoff changed completed animation")
    board.call(tick, 0)
    require(states(board) == [1,0,1,0,1], "timer interfered after handoff")

    # Execute the actual handoff and U-Boot delay/timer routines. The
    # modeled downcounter advances 1 ms per read; no timing assertion
    # here claims to measure the optical hardware.
    for sparse in (False, True):
        board = Board(image)
        board.call(start, 0)
        elapsed = 12000000 if sparse else 0
        if sparse:
            board.call(tick, elapsed)
            require(states(board) == [1,0], "sparse poll skipped a pulse")
            board.call(tick, elapsed)
            require(states(board) == [1,0], "replayed missed edge")
        board.regs[TIMER0] = (~elapsed) & 0xffffffff
        board.timer_step = 24000
        board.call(handoff)
        require(states(board) == [1,0,1,0,1], "handoff failed to finish two pulses")
        board.call(tick, elapsed+48000000)
        require(states(board) == [1,0,1,0,1], "post-handoff edge")
    return "passed: real ARM LED edges and handoff, sparse polls, wrap, FEL/resume isolation"

def config_number(path, key):
    for line in path.read_text().splitlines():
        if line.startswith(key+"="):
            return int(line.split("=",1)[1],0)
    raise AssertionError("missing "+key)

def candidate(directory, deep, baseline):
    prefix = directory/"deep-resume" if deep else directory
    image = (prefix/("BT0-uncaged-deep-candidate.bin" if deep else "BT0-uncaged-source-candidate.bin")).read_bytes()
    check_header(image)
    sym = symbols(prefix/("spl.elf"))
    result = {"sha256": hashlib.sha256(image).hexdigest()}
    result["menu"] = menu_cases(image, sym["save_boot_params"], sym["pb626_report"])
    if baseline:
        require(result["menu"] == baseline["menu"], "Menu/FEL behavior differs from reference")
    board = Board(image)
    result["boot_device"] = board.call(sym["spl_boot_device"])
    # U-Boot's non-OMAP ARM enum: MMC2=2, BOARD=12. The .FEL
    # signature must bypass forced native MMC2 in the source candidates.
    # The historical native reference is not the separate FEL upload SPL.
    require(result["boot_device"] == 2, "wrong native boot device")
    for rtc in (0, 0x53555350):
        require(Board(image, fel=True, rtc=rtc).call(sym["spl_boot_device"]) == 12,
                "FEL upload selected a native storage loader")
    result["fel_upload_dispatch"] = "BOOT_DEVICE_BOARD (with and without SUSP marker)"
    cfg = prefix/"native.config"
    raw = config_number(cfg,"CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR")
    offset = config_number(cfg,"CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_DATA_PART_OFFSET")
    result["raw_sector_function"] = board.call(sym["spl_mmc_get_uboot_raw_sector"],0,raw)
    result["effective_user_lba"] = result["raw_sector_function"]+offset
    require(result["effective_user_lba"] == 80, "wrong raw LBA")
    if baseline:
        require(result["boot_device"] == baseline["boot_device"], "boot device differs from reference")
        require(result["effective_user_lba"] == baseline["effective_user_lba"], "raw LBA differs from reference")
    result["led"] = led_cases(image, sym)
    result["full_boot_probe"] = Board(image,[63]*5).run(0,{0x40008000:"kernel-entry"},probe=True)
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference",type=Path)
    parser.add_argument("--candidates",type=Path)
    parser.add_argument("--report",type=Path,required=True)
    parser.add_argument("--require-reference",action="store_true")
    args = parser.parse_args()
    report = {"scope":"Cortex-A8 + SRAM/LRADC/PE8/timer register subset; no physical DDR/PMIC/MMC model",
              "full_board_qualified":False}
    try:
        base = None
        if args.reference:
            image = args.reference.read_bytes()
            check_header(image)
            require(hashlib.sha256(image).hexdigest() == REFERENCE_SHA, "reference hash differs")
            base = {"sha256":REFERENCE_SHA,"menu":menu_cases(image,0xd70,0x5400)}
            base["boot_device"] = Board(image).call(0x1c5)
            base["effective_user_lba"] = Board(image).call(0x209)
            require(base["effective_user_lba"] == 80, "reference raw LBA")
            base["full_boot_probe"] = Board(image,[63]*5).run(0,{0x40008000:"kernel-entry"},probe=True)
            report["reference"] = base
        else:
            report["reference"] = "NOT CONFIGURED"
        if args.candidates:
            report["native"] = candidate(args.candidates,False,base)
            report["deep_cold_path"] = candidate(args.candidates,True,base)
        require(not args.require_reference or base is not None,
                "Configure PB626_REFERENCE_SPL_B64 to enable mandatory differential validation")
        report["result"] = "tested contract passed" if base else "candidate-only; no differential validation"
    except Exception as e:
        report["result"] = "FAILED"
        report["error"] = repr(e)
        raise
    finally:
        args.report.write_text(json.dumps(report,indent=2)+"\n")
        print(json.dumps(report,indent=2))

if __name__ == "__main__":
    main()
