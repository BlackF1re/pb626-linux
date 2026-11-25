/* Proven kernel handoff, retained byte-for-byte in the raw LBA80 image.
 * Keep the GPIO delays and integrity checks unchanged until tested on hardware. */
.syntax unified
.arm
.arch armv7-a
.section .text,"ax",%progbits
.global _start
_start:
    cpsid if, #0x13
    mov r8, #0x81
    bl trace_mark
    mrc p15, 0, r4, c1, c0, 0
    tst r4, #5
    bne bad_cpu
    bic r4, r4, #0x1800
    mcr p15, 0, r4, c1, c0, 0
    dsb sy
    isb sy
    ldr sp, =0x47ff0000
    mov r0, #0
    ldr r1, =0x01c20c94
    str r0, [r1]
    mov r8, #0x82
    bl trace_mark
    ldr r0, =kernel_start
    ldr r1, =kernel_end
    bl hash_words
    ldr r1, =KERNEL_HASH
    cmp r0, r1
    bne bad_data
    ldr r0, =dtb_start
    ldr r1, =dtb_end
    bl hash_words
    ldr r1, =DTB_HASH
    cmp r0, r1
    bne bad_data
    mov r8, #0x83
    bl trace_mark
    ldr r0, =kernel_start
    ldr r1, =kernel_end
    ldr r2, =0x46000000
    bl copy_words
    ldr r0, =dtb_start
    ldr r1, =dtb_end
    ldr r2, =0x47000000
    bl copy_words
    dsb sy
    ldr r0, =0x46000000
    ldr r1, =kernel_end
    ldr r12, =kernel_start
    sub r1, r1, r12
    add r1, r0, r1
    bl hash_words
    ldr r1, =KERNEL_HASH
    cmp r0, r1
    bne bad_copy
    ldr r0, =0x47000000
    ldr r1, =dtb_end
    ldr r12, =dtb_start
    sub r1, r1, r12
    add r1, r0, r1
    bl hash_words
    ldr r1, =DTB_HASH
    cmp r0, r1
    bne bad_copy
    mov r8, #0x85
    bl trace_mark
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
bad_cpu:
    mov r8, #0x8e
    b fail
bad_data:
    mov r8, #0x8d
    b fail
bad_copy:
    mov r8, #0x8c
fail:
    bl trace_mark
1:  wfe
    b 1b
hash_words:
    ldr r2, =2166136261
    ldr r3, =16777619
1:  cmp r0, r1
    bhs 2f
    ldr r12, [r0], #4
    eor r2, r2, r12
    mul r2, r3, r2
    b 1b
2:  mov r0, r2
    bx lr
copy_words:
    cmp r0, r1
    bxhs lr
1:  ldr r3, [r0], #4
    str r3, [r2],#4
    cmp r0, r1
    blo 1b
    bx lr
trace_mark:
    mov r10, lr
    cmp r8, #0x81
    beq led_three
    cmp r8, #0x85
    bne twi
    mov r7, #5
    b led_begin
led_three:
    mov r7, #3
led_begin:
    ldr r0, =0x01c20068
    ldr r5, [r0]
    orr r1, r5, #0x20
    str r1, [r0]
    dsb sy
    ldr r0, =0x01c20894
    ldr r6, [r0]
    ldr r12, [r0, #12]
    orr r1, r12, #0x100
    str r1, [r0, #12]
    bic r2, r6, #0xf
    orr r2, r2, #1
    str r2, [r0]
    mov r2, #0x04000000
9:  subs r2, r2, #1
    bne 9b
led_loop:
    str r1, [r0, #12]
    mov r2, #0x00800000
1:  subs r2, r2, #1
    bne 1b
    bic r3, r1, #0x100
    str r3, [r0, #12]
    mov r2, #0x00800000
2:  subs r2, r2, #1
    bne 2b
    subs r7, r7, #1
    bne led_loop
    str r6, [r0]
    str r12, [r0, #12]
    dsb sy
    ldr r0, =0x01c20068
    str r5, [r0]
    dsb sy
twi:
    bx r10
.ltorg
.balign 4
.include "payload-check.inc"
kernel_start:
    .incbin "kernel.bin"
.balign 4
kernel_end:
dtb_start:
    .incbin "board.dtb"
.balign 4
dtb_end:
