# PocketBook 626 Plus / Touch Lux 3 · Native Linux

![Linux](https://img.shields.io/badge/Linux-7.2-0f766e?style=flat-square) ![Alpine](https://img.shields.io/badge/Alpine-3.24.4%20armv7-2563eb?style=flat-square) ![Status](https://img.shields.io/badge/status-experimental-d97706?style=flat-square)

**Native Alpine Linux** on the PocketBook 626 Plus (Touch Lux 3): Allwinner A13, 256 MiB RAM and ED060XD4 E Ink (758×1024). A lightweight Xorg/Matchbox desktop boots directly from internal eMMC, without the factory OS, microSD or a host PC.

> [!WARNING]
> Only the late ELAN eKTF2227 / Samsung 8WPD3R eMMC board has been verified (stock U626.5.20.1157, VCOM −2440 mV). Other revisions and panel calibrations are not supported.

## What this project adds

- **BT0-uncaged:** MMC2-safe SPL, direct eMMC-to-Linux boot, ARM kernel wrapper and early Menu-to-FEL recovery.
- **Faster boot:** targeted A13 MBUS DMA dependency fix and early persistent E Ink worker. Observed boot time fell from ~69 s to ~22 s to ~12 s; first acknowledged frame at 4.863 s after kernel start.
- **Custom E Ink renderer:** C WBF decoder, six waveform modes (INIT/DU/GC16/GL16/A2/DU4), temperature-aware transition checks, indexed PIN32 scanout, asynchronous X11 bridge, dirty tiles, grayscale/dithering, fast previews and idle ghosting cleanup.
- **Board support:** ELAN eKTF2227 touch driver, portrait input/button fallback, frontlight PWM fix, USB ACM and dedicated native/RAM/recovery DTBs.
- **Desktop:** lightweight software-rendered Xorg/Matchbox, monochrome theme, on-screen keyboard, battery applet, manual refresh and optional utilities.
- **Recovery:** verified 64 KiB FEL transfers, read-only full eMMC backup, differential restore with 4 MiB SHA-256-checked blocks and optional gzip, offline native image assembler.
- **Research & CI:** reverse-engineered factory boot chain and waveform behavior, pinned and cached paired firmware builds.

> [!NOTE]
> Native boot, USB ACM, touch, grayscale/partial refresh and frontlight were demonstrated on hardware. Wi-Fi firmware loaded and wlan0 appeared; full networking, suspend, charger-only boot, Lima and SD recovery are not qualified. Timings are historical observations, not a controlled benchmark. The consolidated build, offline installer, backup receiver and CID adaptation still need physical validation; the original differential restore was tested on hardware.

## Downloads

Use matching artifacts from successful [system builds](https://github.com/BlackF1re/pb626-linux/actions/workflows/megi-fel.yml) ([consolidation build](https://github.com/BlackF1re/pb626-linux/actions/runs/45680410170)):

- `pb626-mainline-7.2-ram-bundle` — FEL recovery and RAM Linux.
- `pb626-native-system` — rootfs, kernel/DTB and packed `raw-linux.img`.
- `pb626-megi-eink-desktop` — optional RAM desktop; `pb626-desktop-extras` — optional utilities.
- `pb626-emmc-tools` — from the matching [restore build](https://github.com/BlackF1re/pb626-linux/actions/runs/45680410272) ([workflow](https://github.com/BlackF1re/pb626-linux/actions/workflows/restore.yml)).

Extract ZIPs separately and verify `SHA256SUMS` (or `SHA256SUMS.fast` for the recovery helper). Artifacts expire; use manual workflow dispatch if necessary. No local ARM compilation/QEMU is needed for routine deployment.

## Installation & recovery

> [!CAUTION]
> Installation replaces the primary SPL, raw Linux image and **all of p1 (including books and user data)**. Keep verified original factory and working-system backups separately. A broken SPL may prevent FEL recovery; no independent rescue path is established.

### 1. Boot read-only recovery

Requirements: Windows PowerShell 5.1, PowerShell 7.4+ (backup/restore), usbipd-win, WSL2 with `usbutils` and `device-tree-compiler`. The launcher defaults to WSL distro `XperiaDev` (override with `-Distro`).

Keep these verified local inputs in WSL `/root/pb626-lab` (override `PB626_LAB_DIR`):

- `pb626-spl.bin` — exact original lab SPL ([hash](BT0-uncaged/README.md)).
- `direct-entry.bin` — known-working 52-byte ARM entry stub.
- `retry-tools/sunxi-tools-master/sunxi-fel` — executable with [MMU patch](patches/sunxi-fel-keep-mmu-off.patch), or set `PB626_FEL_TOOL`.

> [!IMPORTANT]
> The exact SPL base and FEL stub are not distributed or fully reproducible here. Stop if you lack these inputs; do not substitute an arbitrary SPL. No stock jailbreak is required.

Power off, unplug USB, hold the far-right Menu button and reconnect USB (FEL `1f3a:efe8`). Extract the RAM bundle to `C:\PB626\FEL`. From `C:\PB626`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FEL\Start-PB626.ps1 -BundleDir .\FEL -Variant elan-emmc-backup -Profile diagnostic
```

Elevate PowerShell for initial USB binding if required. Never run SPL twice per power cycle. Confirm Linux USB ACM `0525:a4a7` and the actual COM port (115200 8N1). Recovery leaves eMMC read-only and unmounted; power off if the frontlight remains bright.

### 2. Back up stock firmware

Extract `pb626-emmc-tools` to `C:\PB626\tools`, close the serial terminal and use PowerShell 7.4+ (replace COM12 with your port):

```powershell
.\tools\Backup-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\stock
```

Use a new directory. The tool saves and verifies the entire 7.28 GiB user area, hardware boot0/boot1, EXT_CSD, original CID and `SHA256SUMS`. A post-installation dump is not a factory backup.

Obtain your original `/boot/default.wbf` and verify VCOM and [waveform SHA-256](docs/EINK.md). On the verified factory geometry, `/boot` is FAT16 at LBA 73728; with WSL/Linux `mtools`:

```bash
mcopy -i /mnt/c/PB626/stock/pb626-emmc-user.img@@37748736 ::/default.wbf /mnt/c/PB626/default.wbf
mtype -i /mnt/c/PB626/stock/pb626-emmc-user.img@@37748736 ::/vcom
sha256sum /mnt/c/PB626/default.wbf
```

Stop if the board, VCOM or waveform differs. Never publish dumps, CID, credentials or proprietary calibration.

### 3. Install native Linux

Clone this repo in WSL/Linux. Install `python3`, `e2fsprogs`, `device-tree-compiler`, `mtools`, `clang`, `lld`, `llvm`. Extract `pb626-native-system` to `C:\PB626\native`. Reconstruct the exact SPL locally ([details](BT0-uncaged/README.md)):

```bash
python3 BT0-uncaged/build.py /root/pb626-lab/pb626-spl.bin /mnt/c/PB626/BT0-uncaged.bin
python3 BT0-uncaged/test_hook.py /mnt/c/PB626/BT0-uncaged.bin
```

Build a new offline image set from the repository root (allow ~16 GiB extra for output and temporary work):

```bash
sudo python3 scripts/build-native-image.py \
  --backup /mnt/c/PB626/stock \
  --system /mnt/c/PB626/native \
  --spl /mnt/c/PB626/BT0-uncaged.bin \
  --waveform /mnt/c/PB626/default.wbf \
  --output /mnt/c/PB626/linux \
  --accept-replace-p1
```

The assembler verifies input hashes, geometry, boot extents, DTB and modules. It preserves MBR/EBR, both BT1 copies, remaining partitions and hardware boot areas; EXT_CSD is not programmed. Boot recovery if needed and follow step 4 with `C:\PB626\linux` instead of `stock`. After verification, power off, disconnect USB and boot normally.

### 4. Restore stock (or a verified Linux backup)

Boot recovery (step 1), close the serial terminal, then run preflight before enabling writes:

```powershell
.\tools\Restore-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\stock
.\tools\Restore-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\stock -Write
```

Only after preflight passes, type `RESTORE` followed by the displayed CID. Keep USB connected until **All three eMMC regions match SHA256SUMS**, then power off. For legacy dumps lacking `pb626-emmc-cid.txt`, pass `-ExpectedCid ORIGINAL_CID` to both commands and `--expected-cid ORIGINAL_CID` to the image assembler. Do not override mismatched CID/geometry. [Recovery details](scripts/restore/README.md).

### Optional: RAM desktop

Extract `pb626-megi-eink-desktop` to `C:\PB626\desktop`. Cold-boot its own bundle using step 1 with `-Variant elan-display -Profile standard` and the desktop directory/launcher instead of FEL. Both MMC hosts are disabled. Then:

```powershell
.\desktop\Start-PB626Desktop.ps1 -BundleDir .\desktop -Port COM12 -Waveform C:\PB626\default.wbf
```

Hold Menu for one second and release for a manual reset. USB ACM is an unauthenticated physical root console; no network root login is enabled.

## Reference

[Hardware](docs/HARDWARE-PROFILE.md) · [Factory boot](docs/STOCK-BOOT-CHAIN.md) · [Native boot & measurements](docs/BOOT.md) · [E Ink](docs/EINK.md) · [BT0-uncaged](BT0-uncaged/README.md) · [Recovery](scripts/restore/README.md)

## License & credits

Original contributions: **GPL-2.0-or-later** unless otherwise marked ([LICENSE](LICENSE)). Kernel changes follow the applicable Linux GPL-2.0-only terms and syscall exception; upstream and packaged components retain their own licenses. Do not redistribute reconstructed SPL binaries until the exact U-Boot corresponding source/configuration obligations are resolved.

Special thanks to **[Ondřej Jirman (megi)](https://xnux.eu/)** and [his Linux project](https://xff.cz/kernels/) for the foundational PocketBook support, E Ink V4L2 driver and Allwinner work. This port uses his [pinned Linux 7.2 tree](https://github.com/Arnavion/linux/tree/facc87117511221bb61410e3f92ad8579697f736) via [Arnavion/linux](https://github.com/Arnavion/linux). Thanks also to [linux-sunxi](https://linux-sunxi.org/PocketBook_Touch_Lux_3), [PocketBook A13 sources](https://github.com/pocketbook/Platform_A13), [sunxi-tools](https://github.com/linux-sunxi/sunxi-tools), Matchbox and Alpine.
