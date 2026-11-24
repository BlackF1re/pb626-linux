/* Factory AXF entry. Diagnostic markers use only the previously tested
 * AXP209 data buffer 0x0e, never regulator/voltage settings.
 * Trace calls are bounded and never required for successful boot.
 */
.syntax unified
.arm
.arch armv7-a
.section .text,"ax"
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
    mov r8, #0x82
    bl trace_mark
    mov r0, #0
    ldr r1, =0x01c20c94
    str r0, [r1]
    /* Verify bytes the old AXF reader actually delivered, not just FAT. */
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
    /* Hook only the first ARM NOP, in RAM, to observe an actual fetch
     * at the kernel entry address. The trampoline restores the word.
     * No change to the on-disk zImage, its header, or the compressed data. */
    ldr r0, =kernel_probe
    ldr r1, =kernel_probe_end
    ldr r2, =0x45fff000
    bl copy_words
    ldr r0, =0x46000000
    ldr r1, [r0]
    ldr r2, =0xe1a00000
    cmp r1, r2
    bne bad_data
    ldr r1, =0xeafffbfe /* B 0x45fff000 from 0x46000000 */
    str r1, [r0]
    dsb sy
    mov r8, #0x84
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

/* FNV-style word checksum; detects truncated or corrupted RAM copies.
 * Initial 2166136261, for each little-endian word: (h xor word)*16777619.
 */
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
    str r3, [r2], #4
    cmp r0, r1
    blo 1b
    bx lr

/* Same idle-only, bounded TWI0 transaction used in the prior AXF shim
 * which produced observable markers 0x71/0x7e on this physical board.
 * r8 = marker; clobbers only r0-r3. Wait for STOP/idle before next call.
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
trace_mark:
    ldr r0, =0x01c2006c
    ldr r1, [r0]
    tst r1, #1
    bxeq lr
    ldr r0, =0x01c2ac00
    ldr r1, [r0, #0x0c]
    tst r1, #0x40
    bxeq lr
    ldr r1, [r0, #0x10]
    cmp r1, #0xf8
    bxne lr
    mov r1, #0x60
    str r1, [r0, #0x0c]
    twi_wait 0x08
    mov r1, #0x68
    str r1, [r0, #0x08]
    mov r1, #0x40
    str r1, [r0, #0x0c]
    twi_wait 0x18
    mov r2, #0x0e
    str r2, [r0, #0x08]
    str r1, [r0, #0x0c]
    twi_wait 0x28
    str r8, [r0, #0x08]
    str r1, [r0, #0x0c]
    twi_wait 0x28
trace_stop:
    mov r1, #0x50
    str r1, [r0, #0x0c]
    mov r3, #0x20000
1:  ldr r2, [r0, #0x0c]
    tst r2, #0x10
    bxeq lr
    subs r3, r3, #1
    bne 1b
    bx lr
.ltorg
.balign 4

/* Relocatable code copied to 0x45fff000. All literals in this block move
 * together. The trace target is an absolute address in the original stub.
 * Entry arguments and LR restored; execute the original NOP as a NOP. */
kernel_probe:
    push {r0-r3,r8,lr}
    mov r8, #0x85
    ldr r12, =trace_mark
    blx r12
    ldr r0, =0x46000000
    ldr r1, =0xe1a00000
    str r1, [r0]
    dsb sy
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    mcr p15, 0, r0, c7, c5, 6
    dsb sy
    isb sy
    pop {r0-r3,r8,lr}
    ldr pc, =0x46000004
.ltorg
.balign 4
kernel_probe_end:
.include "payload-check.inc"
kernel_start:
    .incbin "kernel.bin"
.balign 4
kernel_end:
dtb_start:
    .incbin "board.dtb"
.balign 4
dtb_end:
