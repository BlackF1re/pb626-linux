# PocketBook 626 Plus / Touch Lux 3 — Alpine Linux 3.24 / Megi 7.2

**Native eMMC development branch:** retain factory BootROM, BT0, BT1 and boot.axf. The new payload and full Alpine Desktop are built together, using the same pinned kernel revision. Native cold boot has not yet been physically demonstrated. FEL remains for installation, rescue and RAM development.

## Storage and boot

- Factory User Area bootloader regions, MBR/EBR, hardware boot0/boot1 and p5–p10 stay untouched.
- Factory FAT16 p2 keeps its original boot.axf, scripts, recovery, bImage and calibration. The installer adds linux/pb626.bin and changes only the active linux.ini, keeping linux.ini.factory. The file is limited to 8 MiB, loaded by boot.axf at 0x40008000.
- A minimal non-returning ARM wrapper uses SVC mode, moves zImage to 0x46000000 and DTB to 0x47000000, then enters the kernel with r0=0, r1=-1, r2=DTB. No intermediate U-Boot; no overlap with factory BT1.
- p1 is reformatted as ext4 and contains the entire matching Alpine Desktop, kernel modules, and the reader's own waveform copied from p2. **All existing p1 user files are destroyed.** The kernel mounts p1 directly, without a native initramfs. BusyBox init starts Desktop even without USB.

See [verified stock boot chain](docs/PB626-STOCK-BOOT-CHAIN.md) and [archived development notes](docs/archive/README.md). [E Ink audit](docs/EINK-RENDER-STOCK-AUDIT.md) and [live diagnosis](docs/PB626-LIVE-DIAG-2026-11-24.md) retain their limitations. Experimental GPU is not enabled.

## Install from Windows (specific verified ELAN/eMMC unit only)

1. Save and check the complete **factory** eMMC user-area backup, both hardware boot-region images and emmc-info.txt, including personal data. Keep a tested FEL recovery path. The installer checks backup size and loader hashes, live CID, partition geometry, stock boot.axf/bImage/script/INI hashes, VCOM, and space before erasing p1. These checks do not verify every byte of the old backup.
2. Download **pb626-native-emmc-installer** from the successful **PB626 Linux RAM and native eMMC** Actions run. Extract it to a Windows directory. Use the supplied scripts, not mixed artifacts.
3. Fully power off, enter cold FEL with the far-right Menu button while connecting USB. Close PuTTY. From PowerShell in the extracted artifact:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-PB626.ps1 -BundleDir . -FactoryBackupDir C:\PB626\factory-backup -EraseP1
   ```
   Requires the established XperiaDev WSL setup, usbipd, patched FEL tool, trusted SPL and 52-byte entry at /root/pb626-lab (as in previous successful FEL sessions). Elevate PowerShell if usbipd bind needs administrator rights. Use -Distro if needed. FactoryBackupDir must contain pb626-emmc-user.img, pb626-emmc-boot0.img, pb626-emmc-boot1.img, emmc-info.txt.
4. The launcher uploads/verifies the RAM installer, waits for ACM and sends a CID-bound installation command. The installer formats p1, extracts and hashes the complete root, fscks it, then stages and activates the verified boot file. Do not disconnect during installation. After **PB626 INSTALL COMPLETE**, disconnect USB, fully power off and start normally with Power. Physical success requires visible Desktop and input on battery power. A green CI or completed install does not prove cold boot.

If the native boot fails, do not overwrite bootloader regions. Boot the known FEL backup/rescue variant, restore linux.ini from linux.ini.factory and recover original p1 contents from the full factory backup. Existing recovery files and factory kernel are preserved. The factory OS may require its original p1 contents.

## Development and recovery

One workflow builds Alpine and pinned Megi in parallel, assembles a RAM bundle, then builds/reuses matching Desktop and produces the native installer. The RAM Desktop artifact remains usable with Start-PB626.ps1 and Start-PB626Desktop.ps1. Use elan-display / diagnostic with the original waveform. FEL-only device trees disable eMMC, except the dedicated read-only backup/installer variant. Restore helpers remain under scripts/restore.

Kernel: [Megi/Arnavion 7.2](https://github.com/Arnavion/linux/tree/orange-pi-7.2-20260903-2131), commit facc87117511221bb61410e3f92ad8579697f736, plus repository patches. Factory waveform and VCOM are unit-specific; never copy them from an unrelated reader. No raw factory binaries or personal identifiers are included.
