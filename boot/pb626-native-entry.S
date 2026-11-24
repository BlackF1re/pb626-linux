/* Factory BT1 SVC #6 loads this single segment at 0x40008000.
 * It has already disabled MMU/D-cache. Never reuse the live BT1 RAM.
 * Keep source, decompression output, zImage, DTB and temporary stack separate.
 */
.syntax unified
.arm
.arch armv7-a
.section .text,"ax"
.global _start
_start:
    cpsid if, #0x13
    mrc p15, 0, r4, c1, c0, 0
    tst r4, #5
    bne failed
    bic r4, r4, #0x1000
    bic r4, r4, #0x0800
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
1:  ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo 1b
    ldr r0, =dtb_start
    ldr r1, =dtb_end
    ldr r2, =0x47000000
2:  ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo 2b
    dsb sy
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
failed:
    wfe
    b failed
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
