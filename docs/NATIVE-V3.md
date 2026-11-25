# Native v3 cold boot baseline

Observed cold boot: 3 then 5 slow PE8 pulses, no heartbeat, USB or desktop. This confirms the wrapper and zImage entry probe, not original decompressor execution.

Original archive payload SHA256: `4241d9b535068bceeed59d73bd5e78d2d0a7a3d545f2c1b313617181c04e7241`. Source SHA256: `45f50f9f854993dce18cf34473b40e426fbde7fbf0f417d3d020f1d05e1ed6c5`.

Extract kernel from original payload at offset 0x418 up to 0x740724, DTB from 0x740724 to EOF. SHA256 of padded kernel: `f7bf4f5aa3b260892d4dd84bb480a9c57c8b58886fa37df0ce9bbe7ad322f376`; padded DTB: `351d15522cb4bdbca2b2edc14a64e2c48396810cf882279fa51eff302a75e958`. Build in a directory containing source, payload-check.inc, kernel.bin, board.dtb using `clang --target=armv7a-none-eabi -c pb626-native-entry-v3.S -o entry.o` and `ld.lld -Ttext=0x40008000 --oformat=binary entry.o -o pb626v3.bin`. Exact reproduction verified locally. Do not commit proprietary factory dumps.

DTB currently requests init=/sbin/init; prior direct FEL test used /sbin/pb626-emmc-init. Verify installed p1 before changing. Read AXP209 register 0x0e before resetting marker. Keep BT0/BT1, boot.axf and partition geometry untouched.
