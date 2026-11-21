/* boot.axf enters this raw ARM image at 0x40008000. */
.syntax unified
.arm
.arch armv7-a
.section .text, "ax"
.global _start
_start:
    mov r0, #0
    cpsid if, #0x13
    dsb
    mrc p15, 0, r0, c1, c0, 0
    tst r0, #4
    beq disable_mmu
    ldr r1, =0x41000000
    ldr r2, =0x41800000
    bl clean_range
    ldr r1, =0x43200000
    ldr r2, =0x43210000
    bl clean_range
    ldr r1, =0x45000000
    ldr r2, =0x45400000
    bl clean_range
    dsb
disable_mmu:
    bic r0, r0, #1              @ MMU
    bic r0, r0, #4              @ data cache
    bic r0, r0, #0x1000         @ instruction cache
    mcr p15, 0, r0, c1, c0, 0
    isb
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    dsb
    isb

    ldr r3, =0x01c20894         @ PE_CFG1: PE8 is the active-low status LED
    ldr r0, [r3]
    bic r0, r0, #0xf
    orr r0, r0, #1
    str r0, [r3]
    ldr r0, [r3, #0xc]         @ PE_DAT
    orr r1, r0, #0x100
    bic r0, r0, #0x100
    str r0, [r3, #0xc]
    bl pause
    str r1, [r3, #0xc]
    bl pause
    str r0, [r3, #0xc]
    dsb
    mov r0, #0
    mvn r1, #0
    ldr r2, =0x43200000
    ldr pc, =0x41000000

clean_range:
    mcr p15, 0, r1, c7, c10, 1  @ clean to PoC by MVA
    add r1, r1, #32
    cmp r1, r2
    blo clean_range
    bx lr

pause:
    mov r2, #0x6000000
1:  subs r2, r2, #1
    bne 1b
    bx lr

.ltorg
