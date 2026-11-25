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
- **Native system:** Alpine OpenRC, supervised desktop and USB login, unprivileged reader account, on-demand ConnMan networking, bounded logs, zram and graphical system settings.
- **Desktop:** lightweight software-rendered Xorg/Matchbox, monochrome theme, on-screen keyboard, battery applet, manual refresh, frontlight and system status utilities.
- **Recovery:** verified 64 KiB FEL transfers, read-only full eMMC backup, differential restore with 4 MiB SHA-256-checked blocks and optional gzip, offline native image assembler.
- **Research & CI:** reverse-engineered factory boot chain and waveform behavior, pinned and cached paired firmware builds.

> [!NOTE]
> Native boot, USB ACM, touch, grayscale/partial refresh and frontlight were demonstrated on hardware. Wi-Fi firmware loaded and wlan0 appeared; full networking, suspend, charger-only boot, Lima and SD recovery are not qualified. Timings are historical observations, not a controlled benchmark. The consolidated build, offline installer, backup receiver and CID adaptation still need physical validation; the original differential restore was tested on hardware.

## Install, back up or restore

**[Step-by-step Windows guide →](docs/INSTALL.md)**

> [!IMPORTANT]
> This is an experimental, hardware-specific port. The verified FEL SPL and entry stub are still external prerequisites; the repository is not a self-contained one-click installer. Do not flash without a private, verified factory dump and working recovery.

## Build & downloads

Successful [firmware builds](https://github.com/BlackF1re/pb626-linux/actions/workflows/megi-fel.yml) provide:

- `pb626-native-system` — native rootfs, kernel, DTB and raw boot image.
- `pb626-mainline-7.2-ram-bundle` — read-only FEL recovery.
- `pb626-megi-eink-desktop` — optional desktop in RAM (no storage access).
- `pb626-emmc-tools` — independent [backup/restore build](https://github.com/BlackF1re/pb626-linux/actions/workflows/restore.yml).

Firmware builds run on relevant changes to `main`, workflow edits in PRs, or manual **Run workflow**. Ordinary PRs run host-side checks; manually build firmware before merging changes that affect its contents. Recovery builds run only for recovery code/workflow changes. Documentation edits do not rebuild firmware.

Alpine, kernel/modules, DTBs, the static RAM worker, Matchbox/Xorg base and native display binaries have independent, verified caches. Native and RAM packages are assembled from the current inputs. The kernel and Matchbox commits and Alpine base version are pinned; Alpine package repositories can change on a cold cache.

## Technical reference

- [Hardware and factory observations](docs/HARDWARE-PROFILE.md)
- [Factory boot chain and partition layout](docs/STOCK-BOOT-CHAIN.md)
- [Native boot chain and measured results](docs/BOOT.md)
- [Native system administration and acceptance checklist](docs/NATIVE-SYSTEM.md)
- [E Ink waveform and renderer](docs/EINK.md)
- [BT0-uncaged SPL reconstruction](BT0-uncaged/README.md)
- [Recovery format and safeguards](scripts/restore/README.md)

## License & credits

Original contributions: **GPL-2.0-or-later** unless otherwise marked ([LICENSE](LICENSE)). Kernel changes follow the applicable Linux GPL-2.0-only terms and syscall exception; upstream and packaged components retain their own licenses. Do not redistribute reconstructed SPL binaries until the exact U-Boot corresponding source/configuration obligations are resolved.

Special thanks to **[Ondřej Jirman (megi)](https://xnux.eu/)** and [his Linux project](https://xff.cz/kernels/) for the foundational PocketBook support, E Ink V4L2 driver and Allwinner work. This port uses his [pinned Linux 7.2 tree](https://github.com/Arnavion/linux/tree/facc87117511221bb61410e3f92ad8579697f736) via [Arnavion/linux](https://github.com/Arnavion/linux). Thanks also to [linux-sunxi](https://linux-sunxi.org/PocketBook_Touch_Lux_3), [PocketBook A13 sources](https://github.com/pocketbook/Platform_A13), [sunxi-tools](https://github.com/linux-sunxi/sunxi-tools), Matchbox and Alpine.
