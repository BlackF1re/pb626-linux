# PocketBook 626 Plus / Touch Lux 3 — native Alpine Linux

Target: the verified late ELAN eKTF2227 / Samsung 8WPD3R eMMC board,
Allwinner A13, 256 MiB DDR3, ED060XD4. Alpine 3.24.4 ARMv7 with Megi
Linux 7.2, Xorg and E Ink-aware userspace. Not a universal PB626 image:
other revisions and panel calibrations are not supported by this build.

## Reference

- [Hardware and stock system](docs/HARDWARE-PROFILE.md)
- [Factory boot chain](docs/STOCK-BOOT-CHAIN.md)
- [Current boot chain and physical validation](docs/BOOT.md)
- [E Ink / factory waveform reference](docs/EINK.md)
- [BT0-uncaged SPL](BT0-uncaged/README.md)

## Build

[System workflow](.github/workflows/megi-fel.yml) builds a paired set
of artifacts from pinned Megi source
facc87117511221bb61410e3f92ad8579697f736 (Arnavion/linux mirror)
and Alpine 3.24.4. All ARM compilation/emulation happens on CI.

| Artifact | Purpose |
|---|---|
| pb626-mainline-7.2-ram-bundle | FEL RAM and read-only recovery; matching kernel/modules/DTBs |
| pb626-megi-eink-desktop | Optional RAM desktop, no internal flash access |
| pb626-native-system | Native rootfs, native zImage/DTB, packed raw Linux image |
| pb626-desktop-extras | Optional application package |
| pb626-emmc-tools | Full backup and differential restore tools, from [restore workflow](.github/workflows/restore.yml) |
| BT0-uncaged | Manual reconstruction of the tested primary SPL |

Use files from successful matching builds; verify SHA256SUMS.
The system workflow includes the canonical early persistent E Ink renderer.
The integrated build is not yet hardware-validated. No claim of bit-for-bit
reproduction of the previously installed experimental package.

BT0-uncaged can be reconstructed using the original local 24576-byte U-Boot
SPL, the checked-in source patches and assembler. Its base source/config
and toolchain provenance remain missing; do not publish the binary until
corresponding-source obligations are resolved. The original base is not
factory BT0. No factory WBF, device CID or full dump is distributed.

## Recovery / RAM boot

Requirements: Windows PowerShell 5.1 for FEL launch; PowerShell 7.4+
for backup/restore and RAM desktop. usbipd, WSL2 (default XperiaDev),
usbutils, device-tree-compiler. Existing local prerequisites in
/root/pb626-lab (override PB626_LAB_DIR in WSL):
- pb626-spl.bin (exact original lab SPL; see BT0 README for hash)
- direct-entry.bin (known working 52-byte ARM entry)
- retry-tools/sunxi-tools-master/sunxi-fel, built with
  patches/sunxi-fel-keep-mmu-off.patch; or PB626_FEL_TOOL override.

The local FEL prerequisites are not fully reproducible from this repo;
preserve the working copies. No local QEMU or ARM compilation is needed
for routine boot and restore. Never run SPL twice in one power cycle.

Power off, disconnect USB, hold far-right Menu, reconnect USB. Extract
a successful RAM bundle to C:\PB626\FEL and run:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FEL\Start-PB626.ps1 -BundleDir .\FEL -Variant elan-emmc-backup -Profile diagnostic

Use elan-emmc-backup for backup/restore (MMC2 read-only, no partitions
mounted, frontlight off). Use elan-display for the RAM desktop (both MMC
hosts disabled). The native DTB is never accepted by the FEL RAM loader.
Find the actual 0525:a4a7 USB ACM COM port. A successful FEL execute
does not alone prove Linux boot. If frontlight remains bright, power off.

For RAM desktop extract pb626-megi-eink-desktop separately, boot its
elan-display bundle and invoke Start-PB626Desktop.ps1 with -BundleDir,
-Port, and -Waveform pointing to the owner's factory default.wbf.
Do not substitute another panel's calibration. Hold Menu for one second
and release to manually reset the screen. USB console remains available.

## Backup and restore

See [full instructions](scripts/restore/README.md). Boot the recovery
variant above and download pb626-emmc-tools. Close any serial terminal.

    .\Backup-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\backup

Backup creates verified user, boot0 and boot1 raw images, 512-byte EXT_CSD,
original CID and SHA256SUMS in a new private directory. Keep the original
factory dump and a separate current working-system dump. Never publish them.

Restore (first preflight, then explicit write):

    .\Restore-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\backup
    .\Restore-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\backup -Write

For legacy dumps without the private CID file add -ExpectedCid with the
original backup CID to both commands. Type RESTORE <CID> only after
checking preflight. Wait for full three-region SHA256 verification.
The original differential restore was used on hardware. The external-CID
adaptation and new backup tool are not yet hardware-tested.

## Install the built firmware

**This replaces all content of p1 (including existing books/user data)
and the primary bootloader/raw Linux image.** Never flash an unverified
board. First preserve and verify the original and current dumps.
The installer operates offline on a new set of image files, not a disk
device. The existing differential restore then transfers the new dump from
RAM recovery. It leaves MBR/EBR, both BT1 copies, remaining factory partitions
and hardware boot0/boot1 unchanged. EXT_CSD is not programmed.

Extract pb626-native-system and obtain the verified BT0-uncaged.bin plus
the original default.wbf (SHA256 recorded in docs/EINK.md). In WSL/Linux
install python3, e2fsprogs and device-tree-compiler. Run as root, with
adequate space in WSL /tmp and a new output directory (allow roughly
16 GiB for output and work, in addition to the existing dumps).
No mount, loop device, QEMU or direct flash is needed:

    sudo python3 scripts/build-native-image.py \
      --backup /path/to/private-backup \
      --system /path/to/pb626-native-system \
      --spl /path/to/BT0-uncaged.bin \
      --waveform /path/to/default.wbf \
      --output /path/to/new-private-firmware \
      --accept-replace-p1

Legacy backups require --expected-cid ORIGINAL_CID. The tool checks
known prefix, geometry, BT1 copies, SPL and waveform hashes, payload
CRC and DTB, matching modules; builds p1 ext4 and verifies every copied
or changed span. The output has the same manifest format as a backup.
Boot the RAM recovery variant, run Restore-PB626Fast.ps1 first without
-Write and then with -Write using the new output directory.

This offline assembler and clean native build are new integration paths,
not yet a physically verified fresh installer. Do not replace the only
known working installation without a verified rescue setup. Backup
does not guarantee recovery if the primary SPL cannot reach FEL.

## Development boundaries

Only the two RAM modes and the native ELAN/eMMC mode are built. Historical
diagnostic DTBs, temporary boot optimizations and obsolete installers
are available in Git history rather than the working tree. The factory
boot chain remains documented as reference. Local USB ACM is an explicitly
unauthenticated root lab console on physical connection; no network root
login is enabled. Wi-Fi configuration is private and optional. Suspend,
charger-only boot and independent recovery without working SPL are not
qualified.
