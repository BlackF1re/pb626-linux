# BT0-uncaged

A separate, deliberately small primary bootloader component for the late PocketBook 626 Plus / Touch Lux 3 ELAN + eMMC (Allwinner A13) board. On 2026-11-25 the installed SPL booted Alpine Desktop autonomously on one physical reader.

BootROM → BT0-uncaged SPL → raw Linux image (MMC2, LBA 80) → Alpine on p1.
No factory BT0, BT1, boot.axf or FAT boot file participates. BT1 and the FAT partition are preserved on disk for recovery. No SD boot was demonstrated.

**Not a general installer.** Both normal cold boot and Menu-triggered FEL entry have been demonstrated after replacing BT0 on the tested board. FEL version and SRAM reads work; booting native Alpine via the known MMC2-safe SPL from cold Menu FEL also succeeded. The external SD recovery route did not work on the tested board. A failed cold boot may require hardware recovery. Do not flash another revision. Keep a verified full factory eMMC user-area and hardware boot-region backup.

## Build

Dependencies: Python 3, clang, ld.lld, llvm-objcopy. Exact base input is the original lab pb626-spl.bin, 24576 bytes, SHA-256:
7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f.

The base is U-Boot SPL, not factory BT0. Its exact upstream build tree, compiler and configuration have not yet been recovered. This repository does NOT claim a full source rebuild of the underlying U-Boot SPL. The patch source and early-menu assembly are complete and the binary reconstruction is reproducible; build.py refuses any different base or output. The corresponding U-Boot source/configuration and license obligations must be resolved before publishing a binary release. Do not substitute an arbitrary U-Boot build.

    python3 BT0-uncaged/build.py /path/to/pb626-spl.bin BT0-uncaged.bin
    python3 BT0-uncaged/test_hook.py BT0-uncaged.bin

Output: 24576 bytes, SHA-256 1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6.
The build verifies original patch bytes, intermediate safe SPL, eGON header/checksum and final hash. The LRADC polling bound is 0x80000 per conversion, reduced from 0x800000. The ADC setup, five conversions (first discarded), decision logic, and FEL return path are unchanged. The 5249 mocked instruction tests exercise the early LRADC hook, not the entire SoC. No-event idle boot, key/partial-sample recovery, and FEL-thunk return are covered. Cold Menu-triggered FEL communication was subsequently demonstrated on hardware; the modeled paths alone do not establish why the ROM preserved or changed SRAM.


Reconstruction is local only. CI assembles/tests the hook without the private base. Keep the base outside the repository.

SPL uses a legacy uImage at LBA 80, header load/entry 0x40008000.
The wrapper copies zImage to 0x46000000 and DTB to 0x47000000.
It verifies format magic and uses no normal-path diagnostic spin delays or
full-image FNV scans. The packer computes header and payload CRC32.
SPL runtime data-CRC verification is not established.

The regular firmware workflow generates raw-linux.img. For installation,
use the offline image builder and verified full restore as described in
[installation guide](../docs/INSTALL.md). Do not reflash BT0 simply to update Linux. Keep a
complete original backup and the local FEL inputs. Normal cold boot and
Menu FEL worked on the tested installed SPL; independent recovery when
SPL itself fails is unproven. See [boot contract](../docs/BOOT.md).
