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

Megi mainline-based Linux 7.2 tag orange-pi-7.2-20260903-2131,
published 2026-09-03 and pinned to exact commit
facc87117511221bb61410e3f92ad8579697f736.
Mirror: https://github.com/Arnavion/linux/tree/orange-pi-7.2-20260903-2131

Both the 2026 sun4i timer reload race fix and timer minimum-delta fix are
already included in this exact upstream source. We do not apply the old
5.9 patches a second time. The tree includes E Ink, TPS65185 and RTL8XXXU.

## Remaining bring-up blockers

* The FEL SPL, 52-byte ARM entry stub and modified sunxi-fel still come from
  the developer's WSL lab and cannot yet be reproduced from this repository.
* A successful GitHub Actions build is NOT proof of Linux reaching PID1.
* ELAN KTF2K protocol vs elants EKTH3500 is unverified.
* E Ink panel waveforms and userspace refresh, frontlight, GPIO keys, RTC,
  Wi-Fi USB host, power, battery and suspend/resume require real hardware tests.
* Linux 7.2 is mainline-based, **not unmodified upstream**: E Ink remains
  megi-specific. No claim of functional screen refresh without userspace
  waveforms, temperature compensation and panel-safe calibration.

Only move to on-device experiments after CI passes and inspect the actual
published artifacts and known-good lab bootloader. Never flash eMMC.

## Video/display implementation detail (Megi 7.2)

The `FB_SUN5I_EINK` Kconfig symbol is historical: in 7.2 its Kconfig
reads **"eInk display V4L2 output support"**, depends on `VIDEO_DEV`
and selects `VIDEOBUF2_DMA_CONTIG`. A successful build must verify both
`CONFIG_VIDEO_DEV=y` and `CONFIG_FB_SUN5I_EINK=m`. The image includes
`v4l2-ctl` for read-only capability inspection. It does **not** auto-load
or drive the panel from userspace; panel-safe waveforms still need a separate
implementation and per-unit VCOM calibration.

The GPIO status LED PE8 blinks rapidly upon reaching PID 1 and changes to
kernel heartbeat when the RAM shell is ready. This is an independent milestone
if USB gadget never enumerates. LED behavior still needs physical testing.
