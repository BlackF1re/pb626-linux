/* boot.axf enters this raw ARM image at 0x40008000. */
.syntax unified
.arm
.arch armv7-a
.section .text, "ax"
.global _start
_start:
    cpsid if, #0x13
    dsb
    mrc p15, 0, r0, c1, c0, 0
    tst r0, #4
    beq caches_clean
    ldr r1, =_start
    ldr r2, =devicetree_end
clean_payload:
    mcr p15, 0, r1, c7, c10, 1  @ clean payload to PoC
    add r1, r1, #32             @ Cortex-A8 cache line
    cmp r1, r2
    blo clean_payload
    dsb
caches_clean:
    bic r0, r0, #1              @ MMU
    bic r0, r0, #4              @ data cache
    bic r0, r0, #0x1000         @ instruction cache
    mcr p15, 0, r0, c1, c0, 0
    isb
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    dsb
    isb

    ldr r0, =kernel
    ldr r1, =kernel_end
    ldr r2, =0x42000000
    bl copy
    ldr r0, =devicetree
    ldr r1, =devicetree_end
    ldr r2, =0x43200000
    bl copy
    dsb
    mov r0, #0
    mvn r1, #0
    ldr r2, =0x43200000
    ldr pc, =0x42000000

copy:
    ldr r3, [r0], #4
    str r3, [r2], #4
    cmp r0, r1
    blo copy
    bx lr

.ltorg
.balign 4
kernel:
    .incbin "dist/pb626-megi-zImage"
    .balign 4
kernel_end:
devicetree:
    .incbin "pb626-emmc-native.dtb"
    .balign 4
devicetree_end:
