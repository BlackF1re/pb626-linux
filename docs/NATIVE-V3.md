# Native v3 cold boot baseline

Observed cold boot: 3 then 5 slow PE8 pulses, no heartbeat, USB or desktop. This confirms the wrapper and zImage entry probe, not original decompressor execution.

Original archive payload SHA256: `4241d9b535068bceeed59d73bd5e78d2d0a7a3d545f2c1b313617181c04e7241`. Source SHA256: `45f50f9f854993dce18cf34473b40e426fbde7fbf0f417d3d020f1d05e1ed6c5`.

Extract kernel from original payload at offset 0x418 up to 0x740724, DTB from 0x740724 to EOF. SHA256 of padded kernel: `f7bf4f5aa3b260892d4dd84bb480a9c57c8b58886fa37df0ce9bbe7ad322f376`; padded DTB: `351d15522cb4bdbca2b2edc14a64e2c48396810cf882279fa51eff302a75e958`. Build in a directory containing source, payload-check.inc, kernel.bin, board.dtb using `clang --target=armv7a-none-eabi -c pb626-native-entry-v3.S -o entry.o` and `ld.lld -Ttext=0x40008000 --oformat=binary entry.o -o pb626v3.bin`. Exact reproduction verified locally. Do not commit proprietary factory dumps.

DTB currently requests init=/sbin/init; prior direct FEL test used /sbin/pb626-emmc-init. Verify installed p1 before changing. Read AXP209 register 0x0e before resetting marker. Keep BT0/BT1, boot.axf and partition geometry untouched.

## Hardware readback, 2026-11-25

Active v3 matches SHA256. AXP209 0x0e remains 0x80; no USB enumeration. Installed p1 uses BusyBox /sbin/init with /etc/inittab and pb626-native-setup, -desktop and -console. /sbin/pb626-emmc-init does NOT exist. Keep DTB init=/sbin/init; do not use the older init-path experiment.

## v4 experiments

Run `python3 scripts/build-native-v4.py pb626-v3-diagnostic.zip out` with clang/ld.lld. Both retain exact v3 kernel and DTB on disk. Clean has no TWI or kernel probe; 3+5 pulses occur before entering original zImage. Stages patches six verified instructions after RAM copy, uses GPIO-only relocated code at 0x45fff000, with separate pulse groups 3 (wrapper), 4 (head), 5 (before cache), 6 (after cache call), 7 (before decompress), 8 (after decompress), 9 (before Image handoff). Hooked variant is diagnostic only; possible perturbation remains. Test exact v3 then clean via FEL before any cold test. Confirm final rootfs with mountinfo and USB. Preserve factory data.

Gapped build hashes (local Clang/LLD):
- clean: c63321916c2640dbea9f101bb9f94e79d777cbb2841a4e7997a76d78a71e805e
- stages: 36f07592570a6eec37ef7aaad63d8f21b39a638decac25a85d0b22805e1166fb

## Hardware matrix (2026-11-25, v4 archive)

Direct zImage/DTB FEL, exact v3 FEL, v4-clean FEL and v4-stages FEL all mount ext4 on 179:1 and run BusyBox init. Native USB enumerates. Cold clean and cold stages do not enumerate. Cold stages reaches pulse group 9 after the decompressor returned and its cache cleanup path, but before original Image entry. Active file remains pb626v4.bin with stages SHA256 36f07592570a6eec37ef7aaad63d8f21b39a638decac25a85d0b22805e1166fb, contiguous 3724 clusters per installer. Cold USB monitored about 3 minutes. All five SHA256SUMS entries in supplied hardware test archive match. Do not change p1 or the factory loaders.

Offline decompression of exact kernel.bin yields Image size 16370708 (0xf9cc14), SHA256 612534f6cddde64365931e45c07214a69155fc04fde2af12d687268d05eae933, word-wise FNV-style hash 0xb9bf5439. Physical range 0x40008000..0x40fa4c14 (exclusive). First instruction 0xeb0446f6 (BL 0x40119be0). FEL reference dmesg reserves 96 MiB CMA and sees 256 MiB physical DRAM; this does not imply a cold boot DRAM defect. Next experiment verifies Image and DTB at stage 9, and separately probes first Image entry. Test via FEL first; no hardware success for v5 established.
