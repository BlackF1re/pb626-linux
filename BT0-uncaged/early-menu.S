/* SPDX-License-Identifier: GPL-2.0-or-later */
/* PB626 ELAN/eMMC A13. Linked at 0x5000 in zero padding of tested SPL.
 * Called by B at 0xa4 BEFORE save_boot_params, no stack/DRAM/PMIC/MMC use.
 * Normal boot with no ADC/key events, or four consecutive high samples.
 * Any analog key, ambiguous reading or partial conversion timeout -> recovery.
 * FEL upload is NOT a cold ROM entry: the sunxi-fel thunk changes the magic
 * and must regain control to restore swapped SRAM and the FEL stack.
 */
.syntax unified
.arch armv7-a
.arm
.section .text,"ax",%progbits
.global _start
_start:
    adr r12, report
    add r1,r12,#64
    stmia r1,{r4-r9}
    mrs r9,cpsr
    cpsid if
    ldr r1,=0x36324250
    str r1,[r12,#0]
    mov r1,#0
    str r1,[r12,#4]
    str r1,[r12,#8]
    ldr r0,=0x01c22800
    ldr r4,[r0,#0]
    ldr r5,[r0,#4]
    str r4,[r12,#32]
    str r5,[r12,#36]
    str r1,[r0,#4]
    str r1,[r0,#0]
    ldr r1,=0x1f1f
    str r1,[r0,#8]
    ldr r1,=0x02002141
    str r1,[r0,#0]
    dsb sy
    mov r6,#0
    mov r7,#1
sample:
    mov r8,#0x80000
poll:
    ldr r1,[r0,#8]
    tst r1,#1
    bne have_sample
    subs r8,r8,#1
    bne poll
    mov r7,#3
    cmp r6,#0
    bne restore
    tst r1,#0x1e
    moveq r7,#1
    b restore
have_sample:
    tst r1,#0x1e
    movne r7,#2
    ldr r1,[r0,#12]
    and r1,r1,#63
    mov r2,#1
    str r2,[r0,#8]
    cmp r6,#0
    beq next_sample
    add r2,r12,#8
    str r1,[r2,r6,lsl #2]
    str r6,[r12,#8]
    cmp r1,#48
    movlo r7,#2
next_sample:
    add r6,r6,#1
    cmp r6,#5
    blo sample
restore:
    mov r1,#0
    str r1,[r0,#0]
    ldr r1,=0x1f1f
    str r1,[r0,#8]
    str r4,[r0,#0]
    str r5,[r0,#4]
    str r7,[r12,#4]
    dsb sy
    cmp r7,#1
    movweq r3,#0x0d70
    beq finish
    mov r1,#8
    ldr r1,[r1]
    ldr r2,=0x4c45462e
    cmp r1,r2
    bne rom_entry
    movw r1,#0xa200
    cmp lr,r1
    blo rom_entry
    movw r1,#0xa400
    cmp lr,r1
    bhs rom_entry
    mov r3,lr
    b finish
rom_entry:
    mrc p15,0,r1,c1,c0,0
    tst r1,#0x2000
    mov r3,#0x20
    movtne r3,#0xffff
    mov lr,r3
finish:
    mov r2,r9
    add r12,r12,#64
    ldmia r12,{r4-r9}
    msr cpsr_c,r2
    bx r3
.ltorg
.org 0x400
.global report
report:
    .space 64,0
    .space 24,0
