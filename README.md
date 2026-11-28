# PocketBook 626 Plus / Touch Lux 3 · Native Linux

![Linux](https://img.shields.io/badge/Linux-7.2-0f766e?style=flat-square) ![Debian](https://img.shields.io/badge/Debian-13%20armhf-a80030?style=flat-square)

Native Debian 13 armhf on the PocketBook 626 Plus (Touch Lux 3):
Allwinner A13, 256 MiB RAM and ED060XD4 E Ink (758×1024).
A lightweight Xorg/Matchbox desktop boots directly from internal eMMC
without the factory OS, microSD or a host PC.

> [!WARNING]
> Only the late ELAN eKTF2227 / Samsung 8WPD3R eMMC board has been tested.
> Preserve the individual factory waveform and VCOM calibration. Recovery
> and the ability to wake from suspend must be checked on the physical reader.

## Features

- BT0-uncaged: direct eMMC boot, early Menu-to-FEL recovery and retained-DRAM resume.
- Debian minbase, systemd, APT, iwd, USB ACM and unprivileged reader session.
- E Ink V4L2 worker and X11 bridge, waveform-aware partial refresh and grayscale,
  frontlight and touch support, Matchbox keyboard, taskbar and settings.
- Runtime device power management and suspend-to-RAM with a paired kernel and
  resume bootloader. Automatic suspend remains off until physical wake is verified.
- Independent RAM recovery, CID-checked backups and differential restores.

## Install and downloads

Use the [Windows installation guide](docs/WINDOWS-FLASH.md).
Download `pb626-windows-installer` from a successful
[firmware run](https://github.com/BlackF1re/pb626-linux/actions/workflows/request-firmware.yml).
Extract the entire package, run PB626.cmd, and choose Install. It writes the
paired Debian rootfs, kernel/DTB and bootloader; preserve your data first.
Verify cold boot and Menu/FEL recovery before testing suspend.

The firmware workflow builds one Linux kernel, Debian rootfs, RAM recovery,
bootloader, host tools and Windows installer. It checks the compiled suspend
SRAM routine, bootloader model, host tests and actual package manifests.
`pb626-full-build-report` records the exact commit and all required job results.
Build success is not a substitute for physical qualification.

Feature branches request a full build through `.github/firmware-build-request`.
Alpine is no longer built or distributed by the active workflows. Historical
Alpine scripts and notes remain for reference, not as a second distribution.

## Technical reference

- [Suspend and resume](docs/SUSPEND.md)
- [Hardware and factory observations](docs/HARDWARE-PROFILE.md)
- [Factory boot chain and partition layout](docs/STOCK-BOOT-CHAIN.md)
- [E Ink waveform and renderer](docs/EINK.md)
- [BT0-uncaged resume contract](BT0-uncaged/RESUME.md)
- [Recovery format and safeguards](scripts/restore/README.md)

## License & credits

Original contributions: GPL-2.0-or-later unless otherwise marked ([LICENSE](LICENSE)).
Kernel changes follow applicable Linux GPL-2.0-only terms; upstream components
retain their own licenses. See the source and license records in the build.

Thanks to [Ondřej Jirman (megi)](https://xnux.eu/) and
[his Linux project](https://xff.cz/kernels/), the
[Linux 7.2 tree](https://github.com/Arnavion/linux/tree/facc87117511221bb61410e3f92ad8579697f736),
linux-sunxi, PocketBook A13 sources, sunxi-tools, Debian and Matchbox.
