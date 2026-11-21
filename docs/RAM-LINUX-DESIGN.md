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

## USB gadget / frontlight hardware milestone (second RAM test)

The first real 7.2 execution test showed PE8 LED blinking and no Windows
or WSL 0525:a4a7 enumeration. This strongly suggests PID 1 ran, but does
not independently prove that gadget binding succeeded. The frontlight was
reported at full brightness: Linux 7.2 pwm_bl ignores DT default-brightness-
level if the brightness-levels array is absent. The new DTB specifies both.
The new /init also writes brightness=0 and bl_power=4 where available.

For one controlled test, observe PE8 *after 30 seconds*:

* Fast even 150ms on/off: PID1 started; USB diagnostic has not concluded
* 100ms on / 900ms off: no UDC exposed to Linux
* 300ms on / 700ms off: configfs gadget creation failed
* 700ms on / 300ms off: UDC found, but gadget bind failed
* Kernel heartbeat double pulse: UDC gadget binding accepted by kernel

Do not conflate gadget binding with host USB enumeration. If the frontlight
remains intense after the off-request, **stop the test and power down**.
No persistent storage access is required and no flashing mechanism is added.

## Third FEL boot: UDC bound, no host enumeration; frontlight still on

On 2026-11-21 the second RAM test with 7.2 reached kernel LED heartbeat
**after ConfigFS UDC bind**, yet Windows and WSL saw no USB descriptor,
and the frontlight remained fully illuminated despite PWM backlight=0.

This narrows USB to PHY/session detection, pull-up, or host path; does not
prove PG1 is the cause. Upstream megi PocketBook DTS declares PG1 as VBUS
sense with a warning `might not work, need to test`. The sun4i_usb_phy
source trusts this GPIO; when unconfigured, it defaults to VBUS present.

**Experimental `elan-usbtest` DTB only:** remove the unverified PG1
`usb0_vbus_det-gpios` so PHY VBUS detection takes its fallback; keep
`dr_mode=peripheral`. Disable the PWM/backlight drivers and reserve PB4,
the documented active-high frontlight enable, as a GPIO hog driven LOW.
This is a test, not a permanent board definition. If the frontlight remains
bright, stop the experiment and power off; do not invert PB4 without more
measurements. No eMMC writes or firmware flashing are involved.

A separate LED code can distinguish a USB gadget bound to UDC but never
advancing from `not attached` to enumerating/configured states.

## 2026-11-21 factory baseline and isolated diagnostic variants

The owner verified that both full-range frontlight (including OFF) and USB
connection work in the actual manufacturer's firmware. The hardware is
therefore not evidently broken; our Linux driver/pin-control initialization
is suspect. The factory FEX also declares PG1 as USB VBUS sense; do not
assume that overriding PG1 is the correct permanent fix.

Two independent test stages avoid changing USB and backlight simultaneously:

1. `elan-lightoff` retains the stock PG1 VBUS GPIO and changes only the
   frontlight/PWM path (drivers off; PB4 hog output-low). Test whether light
   goes off, before waiting for USB or attempting any other variant.
2. Only if that is safe, `elan-usbtest` uses the SAME light-off configuration
   and additionally bypasses PG1 VBUS detection, to test whether the modern
   sun4i PHY's fallback establishes enumeration. This is strictly
   experimental; no modification to the normal `elan` DTB.

A controlled observation of the frontlight does NOT prove that PB4 is
correctly wired; if it stays bright, halt the test. The full RAM image
still never writes to internal eMMC or SPI NOR.

## Hardware milestone confirmed: Alpine 3.24.4 / USB ACM configured

On 2026-11-21, the observed ELAN PocketBook 626 Plus physically booted
Megi Linux `7.2.0-gfacc87117511` into the full RAM initramfs and exposed
an interactive Alpine Linux 3.24.4 shell over USB ACM. The Windows host saw
`0525:a4a7` / serial `PB626RAM01` on COM12 (port number is ephemeral).
User-executed commands confirmed `uname -a` (armv7l), `/etc/os-release`,
and UDC state `configured`. These are **direct hardware observations**,
not a CI-only claim. No eMMC writes were requested.

Controlled A/B result on the **same** reader:

* `elan` — bright frontlight, no host USB enumeration.
* `elan-lightoff` — PB4 held output-low via a GPIO hog, PWM/backlight
  drivers disabled; frontlight **went off**, USB still did not enumerate
  with factory-described PG1 VBUS sensing.
* `elan-usbtest` — same frontlight-off configuration plus removal of
  `usb0_vbus_det-gpios` referencing PG1. **Frontlight off and USB ACM
  enumerated**, then a real shell answered commands.

The factory OS also uses PG1 for VBUS detection and supports normal USB,
so `elan-usbtest` is explicitly an **experimental workaround**, not evidence
that PG1 should be removed from a shipping DTS. The new Linux PHY handling
or GPIO/pinctrl configuration needs more investigation. Likewise, holding
PB4 low is a safety-first diagnostic, not functional brightness control.

Remain careful with E Ink waveform and VCOM configuration and do not claim
working display refresh/touch/Wi-Fi or production readiness.
