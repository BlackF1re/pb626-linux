/* The factory boot.axf loads bImage at 0x40008000. */
.syntax unified
.arm
.arch armv7-a
.section .text, "ax"
.global _start
_start:
    mov r0, #0
    cpsid if, #0x13
    bl trace_factory_handoff
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
    bl copy_image
    ldr r0, =kernel
    ldr r1, =kernel_end
    ldr r2, =0x42000000
    bl copy_image
    b disable_mmu

/* Copy an image and publish it even if the factory loader left D-cache on. */
copy_image:
    cmp r0, r1
    bxeq lr
    mov r5, r2
copy:
    ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo copy
    tst r4, #4
    bxeq lr
clean:
    mcr p15, 0, r5, c7, c10, 1
    add r5, r5, #32
    cmp r5, r2
    blo clean
    bx lr
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

/* AXP209 data buffer survives an A13 power cycle with the battery fitted.
 * Use the TWI0 configuration left by boot.axf, only if the bus is idle.
 */
.macro twi_wait expected
    mov r3, #0x20000
.Lwait\@:
    ldr r2, [r0, #0x0c]
    tst r2, #8
    bne .Lstatus\@
    subs r3, r3, #1
    bne .Lwait\@
    b trace_stop
.Lstatus\@:
    ldr r2, [r0, #0x10]
    cmp r2, #\expected
    bne trace_stop
.endm

trace_factory_handoff:
    ldr r0, =0x01c2006c          @ APB1 gate, bit 0 is TWI0
    ldr r1, [r0]
    tst r1, #1
    bxeq lr
    ldr r0, =0x01c2ac00          @ TWI0, PB0/PB1
    ldr r1, [r0, #0x0c]
    tst r1, #0x40               @ bus enabled
    bxeq lr
    ldr r1, [r0, #0x10]
    cmp r1, #0xf8               @ idle
    bxne lr
    mov r1, #0x60               @ START, TWI enabled
    str r1, [r0, #0x0c]
    twi_wait 0x08
    mov r1, #0x68               @ AXP209 address 0x34, write
    str r1, [r0, #0x08]
    mov r1, #0x40
    str r1, [r0, #0x0c]
    twi_wait 0x18
    mov r2, #0x0e               @ data buffer register
    str r2, [r0, #0x08]
    str r1, [r0, #0x0c]
    twi_wait 0x28
    mov r2, #0x61               @ factory wrapper entered
    str r2, [r0, #0x08]
    str r1, [r0, #0x0c]
    twi_wait 0x28
trace_stop:
    mov r1, #0x50               @ STOP, TWI enabled
    str r1, [r0, #0x0c]
    bx lr

.ltorg
.balign 4
uboot:
    .incbin "u-boot/u-boot.bin"
    .balign 4
uboot_end:
kernel:
    .incbin "factory-kernel.bin"
    .balign 4
kernel_end:
