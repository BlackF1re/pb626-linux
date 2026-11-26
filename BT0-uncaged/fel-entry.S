/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Source replacement for the lost RAM handoff stub, not a claim of
 * byte identity. Execute at 0x41000000 after the patched FEL tool. */
.syntax unified
.arch armv7-a
.arm
.section .text,"ax",%progbits
.global _start
_start:
    cpsid if, #0x13
    mrc p15, 0, r4, c1, c0, 0
    tst r4, #5
    bne bad_cpu
    bic r4, r4, #0x1800
    mcr p15, 0, r4, c1, c0, 0
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    mcr p15, 0, r0, c7, c5, 6
    dsb sy
    isb sy
    mvn r1, #0
    ldr r2, =0x43200000
    ldr r3, =0x42000000
    mov lr, #0
    bx r3
bad_cpu:
    b bad_cpu
.ltorg
