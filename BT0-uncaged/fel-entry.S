/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Recovered from the original laboratory direct-entry.S. The 52-byte
 * result must match the hardware-tested binary exactly. */
.syntax unified
.arm
.text
.global _start
_start:
    cpsid if, #0x13
    mrc p15, 0, r3, c1, c0, 0
    bic r3, r3, #0x5
    bic r3, r3, #0x1800
    mcr p15, 0, r3, c1, c0, 0
    dsb sy
    isb sy
    mov r0, #0
    mvn r1, #0
    ldr r2, =0x43200000
    ldr r3, =0x42000000
    bx r3
