/* The factory boot.axf loads bImage at 0x40008000. */
.syntax unified
.arm
.arch armv7-a
.section .text, "ax"
.global _start
_start:
    mov r0, #0
    cpsid if, #0x13
    /* Mark the factory handoff before touching the U-Boot image. */
    ldr r0, =0x01c208a0          @ PE data register
    ldr r1, [r0]
    orr r1, r1, #(1 << 8)       @ PE8 LED off
    str r1, [r0]
    ldr r2, [r0, #-8]           @ PE_CFG2
    bic r2, r2, #7
    orr r2, r2, #1              @ PE8 output
    str r2, [r0, #-8]
    /* The stock loader may leave the timer clock gated. */
    mov r2, #0x10000000
1:
    subs r2, r2, #1
    bne 1b
    mrc p15, 0, r4, c1, c0, 0
    ldr r0, =uboot
    ldr r1, =uboot_end
    ldr r2, =0x4a000000
copy:
    ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo copy
    tst r4, #4
    beq disable_mmu
    ldr r0, =0x4a000000
    add r2, r2, #31
clean:
    mcr p15, 0, r0, c7, c10, 1
    add r0, r0, #32
    cmp r0, r2
    blo clean
disable_mmu:
    dsb
    bic r4, r4, #1
    bic r4, r4, #4
    bic r4, r4, #0x1000
    mcr p15, 0, r4, c1, c0, 0
    isb
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    dsb
    isb
    ldr pc, =0x4a000000

.ltorg
.balign 4
uboot:
    .incbin "u-boot/u-boot.bin"
    .balign 4
uboot_end:
