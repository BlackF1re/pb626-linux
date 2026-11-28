#!/usr/bin/env python3
"""Execute the actual SRAM PM object against a deliberately limited MMIO model.

This checks control flow, register/stack integrity and abort transactions.
It does not model electrical retention, PLLs, PMIC power loss or the watchdog.
A successful cut is an explicit model stop at the final I2C STOP.
"""
import pathlib
import struct
import subprocess
import sys

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE, UC_MEM_WRITE
from unicorn.arm_const import (
    UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
    UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
    UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11,
    UC_ARM_REG_R12, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC,
)

CODE, STACK, DRAM, TWI, TIMER = 0x10000, 0x20000, 0x30000, 0x40000, 0x50000
RETURN = CODE + 0xf00
SP = STACK + 0x800
MAGIC = 0x53555350
DCR, DPCR, HPCR = 4, 0x23c, 0x250
CONTROL, STATUS, DATA = 0xc, 0x10, 8
RTC_MAGIC = 0x128
REGS = [UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7,
        UC_ARM_REG_R8, UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11,
        UC_ARM_REG_R12]
VALUES = [0x12340000 + i for i in range(len(REGS))]

def require(ok, message):
    if not ok:
        raise AssertionError(message)

def put(uc, addr, value):
    uc.mem_write(addr, struct.pack("<I", value))

def get(uc, addr):
    return struct.unpack("<I", uc.mem_read(addr, 4))[0]

def run(code, entry, fatal, *, failure=None, stuck=None, cut=True, mask=0x55555555):
    uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
    for base in (CODE, STACK, DRAM, TWI, TIMER):
        uc.mem_map(base, 0x1000)
    require(len(code) < RETURN - CODE, "SRAM code exceeds model code area")
    uc.mem_write(CODE, code)
    for reg, value in zip(REGS, VALUES):
        uc.reg_write(reg, value)
    for reg, value in [(UC_ARM_REG_R0, DRAM), (UC_ARM_REG_R1, TWI),
                       (UC_ARM_REG_R2, 0x04), (UC_ARM_REG_R3, TIMER),
                       (UC_ARM_REG_SP, SP), (UC_ARM_REG_LR, RETURN)]:
        uc.reg_write(reg, value)
    original = [0xa5000000 | (i << 8) | ((mask >> i) & 1) for i in range(31)]
    for i, value in enumerate(original):
        put(uc, DRAM + HPCR + 4*i, value)
    put(uc, TIMER + RTC_MAGIC, MAGIC)
    put(uc, DRAM + DCR, 0x305d)
    put(uc, TWI + CONTROL, 0x40)
    statuses = [0x08, 0x18, 0x28, 0x28]
    # START, address, register, data: four bus states.
    phase = -1
    ctrl, status, command = 0x40, 0, 0
    commands, bytes_sent = [], []
    result = None
    refresh, pad_held = False, False
    stop_count = 0

    def dram(uc, access, addr, size, value, _):
        nonlocal command, refresh, pad_held
        off = addr - DRAM
        require(size == 4, "unexpected DRAMC access width")
        if access == UC_MEM_WRITE:
            if off == DCR:
                command = (value >> 27) & 31
                commands.append(command)
                if command == 0x12:
                    refresh = True
                elif command == 0x17:
                    refresh = False
            elif off == DPCR:
                pad_held = bool(value & 1) or (pad_held and stuck == "pad")
        elif off == DCR:
            val = get(uc, addr)
            put(uc, addr, val if stuck == command else val & ~(1 << 31))
        elif off == DPCR:
            put(uc, addr, int(pad_held))

    def twi(uc, access, addr, size, value, _):
        nonlocal phase, ctrl, status, result, stop_count
        off = addr - TWI
        require(size == 4, "unexpected TWI access width")
        if access == UC_MEM_WRITE:
            if off == DATA:
                bytes_sent.append(value)
            elif off == CONTROL:
                ctrl = value & 0x40
                if value & 0x10:
                    stop_count += 1
                    if failure is None and phase == 3 and cut:
                        require(refresh and pad_held, "PMIC cut before DRAM retention")
                        result = "cut"
                        uc.emu_stop()
                else:
                    phase += 1
                    require(phase < len(statuses), "unexpected extra I2C phase")
                    status = 0x20 if failure == phase else statuses[phase]
                    if failure != "timeout":
                        ctrl |= 8
        elif off == CONTROL:
            put(uc, addr, ctrl)
        elif off == STATUS:
            put(uc, addr, status)

    def stack(uc, access, addr, size, value, _):
        require(not refresh and not pad_held, "stack accessed while DRAM unavailable")

    def on_fatal(uc, addr, size, _):
        nonlocal result
        # Stop at the actual fatal WFI, after the invalidation store and DSB.
        require(get(uc, TIMER + RTC_MAGIC) == 0, "fatal path left resume armed")
        result = "fatal"
        uc.emu_stop()

    uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, dram, begin=DRAM, end=DRAM+0xfff)
    uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, twi, begin=TWI, end=TWI+0xfff)
    uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, stack, begin=STACK, end=STACK+0xfff)
    wfi = fatal + 12
    require(struct.unpack_from("<I", code, wfi)[0] == 0xe320f003, "fatal WFI encoding changed")
    uc.hook_add(UC_HOOK_CODE, on_fatal, begin=CODE+wfi, end=CODE+wfi)
    uc.emu_start(CODE + entry, RETURN, count=80_000_000)
    if result is None:
        require(uc.reg_read(UC_ARM_REG_PC) == RETURN, "execution exhausted instruction budget")
        result = "abort"
    ports = [get(uc, DRAM + HPCR + 4*i) for i in range(31)]
    if result == "abort":
        require(uc.reg_read(UC_ARM_REG_R0) == 1, "abort returned success")
        require([uc.reg_read(r) for r in REGS] == VALUES, "callee-saved registers changed")
        require(uc.reg_read(UC_ARM_REG_SP) == SP, "stack pointer changed")
        require(ports == original, "original DRAM host-port bits not restored")
        require(commands == [0x15, 0x12, 0x17, 0x13], "wrong abort DRAM sequence")
        require(not refresh and not pad_held and stop_count == 1, "incomplete abort")
    elif result == "cut":
        require(ports == [v & ~1 for v in original], "ports active at cut")
        require(commands == [0x15, 0x12], "wrong entry DRAM sequence")
        require(bytes_sent == [0x68, 0x12, 0x04], "wrong PMIC transaction")
        require(get(uc, TIMER + RTC_MAGIC) == MAGIC, "valid resume lost")
    return result

def main():
    obj, raw = map(pathlib.Path, sys.argv[1:3])
    code = raw.read_bytes()
    syms = {}
    for line in subprocess.check_output(["arm-linux-gnueabihf-nm", str(obj)], text=True).splitlines():
        cols = line.split()
        if len(cols) == 3:
            syms[cols[2]] = int(cols[0], 16)
    entry, fatal = syms["sun5i_standby_blob"], syms["fatal"]
    require(run(code, entry, fatal) == "cut", "normal modeled cut")
    for mask in (0, 0x7fffffff, 0x55555555, 0x2aaaaaaa):
        for phase in range(4):
            require(run(code, entry, fatal, failure=phase, mask=mask) == "abort",
                    "I2C failure did not unwind")
    require(run(code, entry, fatal, failure="timeout") == "abort", "TWI timeout")
    require(run(code, entry, fatal, stuck=0x12) == "fatal", "stuck self-refresh")
    require(run(code, entry, fatal, failure=0, stuck="pad") == "fatal", "stuck pads")
    require(run(code, entry, fatal, cut=False) == "fatal", "PMIC ACK without power cut")
    print("Actual ARM SRAM: modeled cut, 16 bus aborts, timeout and fatal paths passed")

if __name__ == "__main__":
    main()
