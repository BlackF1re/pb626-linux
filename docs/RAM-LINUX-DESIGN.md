# Full RAM Linux / PB626 architecture

The default FEL artifact is a full Alpine ARMv7 RAM root with version-matched
kernel modules, firmware packages, a rescue shell, USB configfs ACM and hardware
inspection. It does NOT depend on a microSD card. It is not yet hardware-verified.

## Boot and storage boundary

All FEL transfers write **only RAM**. MMC2 (factory eMMC) must be disabled
in the DTB and is checked again by the host loader. The RAM init refuses
external root handoff when an MMC-type internal device is seen. SPI NOR and
panel VCOM must not be programmed by diagnostic userspace.

A future normal external rootfs can be selected explicitly with
`pb626.root=sd` in FDT `/chosen/bootargs`. It is mounted only when a
removable SD-type card has the expected image marker and init binary, and
then mounted `ro,noload`. Current default is RAM Linux, with no storage
automount and no flashing.

## Pinned source and 2026 backports

Linux 5.9 Megi commit e98db7f114d7602c6b847d76e183787f0c97cf5b.
Backports:
- Ondrej Jirman, A13 pending-reload timer fix (2026-07-25):
  https://lore-kernel.gnuweeb.org/lkml/9e9003b7-0331-4b37-9b06-5e9de887199e@oss.qualcomm.com/T/
- Linux d21808328225ab8cee46885bf9a0dffcefbe630e, minimum timer delta.

Do not claim these are **all** megi fixes published since 2020; that requires
an independently versioned audit of all his later branches and mailing-list
patch series.

## Remaining bring-up blockers

* The FEL SPL, 52-byte ARM entry stub and modified sunxi-fel still come from
  the developer's WSL lab and cannot yet be reproduced from this repository.
* A successful GitHub Actions build is NOT proof of Linux reaching PID1.
* ELAN KTF2K protocol vs elants EKTH3500 is unverified.
* E Ink panel waveforms and userspace refresh, frontlight, GPIO keys, RTC,
  Wi-Fi USB host, power, battery and suspend/resume require real hardware tests.
* Linux 5.9 is end-of-life. Long-term kernel modernization is separate.

Only move to on-device experiments after CI passes and inspect the actual
published artifacts and known-good lab bootloader. Never flash eMMC.
