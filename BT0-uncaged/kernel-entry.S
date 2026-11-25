/* RAM/FEL tested: preserve the proven CPU setup and kernel relocation.
 * No delay or diagnostic hash on the successful path. GPIO PE8 is active low.
 * Only the raw Linux image changes; the installed BT0 is not touched. */
.syntax unified
.arm
.arch armv7-a
.section .text,"ax"
.global _start
_start:
    cpsid if, #0x13
    bl led_on
    mrc p15, 0, r4, c1, c0, 0
    tst r4, #5
    bne fatal
    bic r4, r4, #0x1800
    mcr p15, 0, r4, c1, c0, 0
    dsb sy
    isb sy
    ldr sp, =0x47ff0000
    mov r0, #0
    ldr r1, =0x01c20c94
    str r0, [r1]
    ldr r0, =kernel_start
    ldr r1, =kernel_end
    ldr r2, =0x46000000
    bl copy_words
    ldr r0, =dtb_start
    ldr r1, =dtb_end
    ldr r2, =0x47000000
    bl copy_words
    dsb sy
    /* Cheap format checks, not a substitute for an integrity check. */
    ldr r0, =0x46000024
    ldr r1, [r0]
    ldr r2, =0x016f2818
    cmp r1, r2
    bne fatal
    ldr r0, =0x47000000
    ldr r1, [r0]
    ldr r2, =0xedfe0dd0
    cmp r1, r2
    bne fatal
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    mcr p15, 0, r0, c7, c5, 6
    dsb sy
    isb sy
    mvn r1, #0
    ldr r2, =0x47000000
    mov lr, #0
    ldr r3, =0x46000000
    bx r3
copy_words:
    cmp r0, r1
    bxhs lr
1:  ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo 1b
    bx lr
led_on:
    ldr r0, =0x01c20068
    ldr r1, [r0]
    orr r1, r1, #0x20
    str r1, [r0]
    dsb sy
    ldr r0, =0x01c20894
    ldr r1, [r0, #12]
    bic r1, r1, #0x100
    str r1, [r0, #12]
    ldr r1, [r0]
    bic r1, r1, #0xf
    orr r1, r1, #1
    str r1, [r0]
    dsb sy
    bx lr
fatal:
    bl led_on
    ldr r0, =0x01c208a0
1:  ldr r1, [r0]
    eor r1, r1, #0x100
    str r1, [r0]
    dsb sy
    mov r2, #0x00400000
2:  subs r2, r2, #1
    bne 2b
    b 1b
.ltorg
.balign 4
kernel_start:
    .incbin "kernel.bin"
.balign 4
kernel_end:
dtb_start:
    .incbin "board.dtb"
.balign 4
dtb_end:
