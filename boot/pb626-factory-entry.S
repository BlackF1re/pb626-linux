/* boot.axf loads this raw image at 0x40008000 with MMU and caches off. */
.syntax unified
.arm
.arch armv7-a
.section .text, "ax"
.global _start
_start:
    cpsid if, #0x13

    /* Two pulses mark entry from the factory loader on ELAN. */
    ldr r4, =0x01c20894         @ PE_CFG1
    ldr r0, [r4]
    bic r0, r0, #0xf
    orr r0, r0, #1
    str r0, [r4]
    ldr r0, [r4, #0xc]         @ PE_DAT
    bic r5, r0, #0x100         @ Active-low PE8
    orr r6, r0, #0x100
    str r5, [r4, #0xc]
    bl pause
    str r6, [r4, #0xc]
    bl pause
    str r5, [r4, #0xc]
    bl pause
    str r6, [r4, #0xc]

    /* Use the RAM addresses already verified via FEL. The factory
     * loader has handed off, so its former work area can be reused.
     * Keep all copies stackless and never return to BT1.
     */
    ldr r0, =dtb
    ldr r1, =dtb_end
    ldr r2, =0x43200000
    bl copy_words
    ldr r0, =initrd
    ldr r1, =initrd_end
    ldr r2, =0x45000000
    bl copy_words
    ldr r0, =kernel
    ldr r1, =kernel_end
    ldr r2, =0x42000000
    bl copy_words

    dsb
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0  @ Invalidate I-cache
    dsb
    isb
    mvn r1, #0
    ldr r2, =0x43200000
    ldr pc, =0x42000000

copy_words:
    ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo copy_words
    bx lr

pause:
    mov r0, #0x6000000
1:  subs r0, r0, #1
    bne 1b
    bx lr

.ltorg
.balign 4
dtb:
    .incbin "pb626-emmc-native.dtb"
    .balign 4
dtb_end:
initrd:
    .incbin "pb626rd.gz"
    .balign 4
initrd_end:
kernel:
    .incbin "dist/pb626-megi-zImage"
    .balign 4
kernel_end:
