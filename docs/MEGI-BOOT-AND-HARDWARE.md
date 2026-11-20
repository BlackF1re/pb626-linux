# PB626 Plus: Megi 5.9 source-of-truth, FEL boot and hardware acceptance

## Upstream origin and retained patches

The source of the complete PocketBook Touch Lux 3 port is **not** vanilla
upstream/mainline Linux. The build checks out the entire Megi-derived kernel
from `https://github.com/sailfish-on-dontbeevil/kernel-megi`, branch
`orange-pi-5.9`, and **refuses to build** unless `HEAD` is exactly
`e98db7f114d7602c6b847d76e183787f0c97cf5b`.

This guarantees that every source change present at that commit (including
all changes beyond the handful explicitly listed here) is included in the
build. It does **not** copy the full Megi kernel source into this repo.
If upstream becomes unavailable, reproducibility will need a source mirror or
vendored full patch series. We must not claim that all Megi kernel patch files
are literally stored here.

Important features from the pinned kernel (not replacements by vanilla
mainline drivers):

| Component | Source within the pinned Megi tree | Build state / limitation |
|---|---|---|
| Whole Touch Lux 3 board | `arch/arm/boot/dts/sun5i-a13-pocketbook-touch-lux-3.dts` | Baseline for all PB626 variants |
| Original kernel configuration | `arch/arm/configs/pocketbook_touch_lux_3_defconfig` | CI enables selected built-in drivers |
| E Ink TCON0/DEBE pipeline | `drivers/video/fbdev/sun5i-eink.c`, `sun5i-eink-neon.c` | `CONFIG_FB_SUN5I_EINK=m`; no verified waveform refresh program |
| E Ink panel power/VCOM | `drivers/regulator/tp65185x.c` | `CONFIG_REGULATOR_TP65185X=y`; no panel render accepted |
| AXP209 and battery | kernel MFD, regulator, power-supply drivers | On-device validation still required |
| Frontlight PWM PB2, enable PB4 | Megi board DTS + PWM/backlight drivers | Observed full-on, brightness range unverified |
| E Ink SPI NOR waveform storage | SPI2 + JEDEC SPI NOR | Read-only use not yet validated; do not program |
| USB gadget | MUSB sunxi + configfs ACM | Built in; Linux `0525:a4a7` is NOT yet observed |
| External microSD | MMC0 (PF pins) | 12 MHz cap; I/O stalls previously observed |
| Wi-Fi RTL8188EUS | internal USB EHCI/OHCI + `r8188eu` | Module on SD image; unverified with new kernel |
| Physical buttons | LRADC Home/Menu + gpio keys | Not tested on new kernel |
| Touchscreen | stock `elan-ktf2k` at I2C2 `0x15` | `elan,ekth3500` binding is provisional and **may be incompatible** |

### Changes for THIS reader (separate from the original Megi DTS)

- `board/megi/common-sd.fragment`: new `/memory@40000000` node (256 MiB
  physical RAM) required by the raw 52-byte FEL ARM entry, since U-Boot is
  bypassed. Disable `mmc2` to avoid probing factory eMMC. Cap `mmc0` at
  12 MHz to mitigate observed removable microSD stalls; not proven stable.
- `board/megi/elan.fragment`: change touchscreen from the original Cypress
  `0x24` to the observed ELAN KTF2K `0x15`; describe touch power via PE5;
  set TPS65185 VCOM **magnitude** 2.440 V for this one reader only.
  Do not use this VCOM setting on other panel revisions.
- `.github/workflows/megi-fel.yml`: add `/chosen/linux,initrd-start` and
  `linux,initrd-end` after initramfs compression. The direct ARM entry does
  not add U-Boot FDT fixups, and the image is loaded at `0x45000000`.
- `patches/sunxi-fel-keep-mmu-off.patch`: source patch for FEL transport.
  The A13 ROM enables MMU; the previous generic Windows FEL tool restored
  it after SPL and USB timed out. A locally patched Linux FEL tool with
  `PB626_FEL_KEEP_MMU_OFF=1` has passed SPL and 64 KiB RAM readback tests.

## Current observed boot boundary (2026-11-21)

A cold FEL session has verified by **byte-for-byte DRAM readback**:
- zImage: `0x42000000`, 6,047,808 bytes;
- ELAN diagnostic DTB: `0x43200000`, 21,033 bytes;
- diagnostic initramfs: `0x45000000`, 3,185,909 bytes;
- 52-byte ARM entry stub: `0x41000000`.

`execute 0x41000000` exits 0, then FEL disconnects from USB. The frontlight
can turn on at apparent full brightness, but **no Linux gadget** `0525:a4a7`
was observed, no USB shell or kernel log was captured, and successful Linux
boot has NOT been established. A blank E Ink screen is expected without a
waveform-aware userspace. Do not claim that the display, backlight, Wi-Fi or
ELAN touch are working.

No kernel telemetry is available from the current attempted boot. The
original Megi DTS, config and patches cannot rule out other problems on
this specific board revision without a boot log.

## Boot loader (supported workflow only)

Windows: `scripts/Start-PB626.ps1 -BundleDir C:\PB626\bundle -Variant elan
-Profile standard`. Linux under WSL: `scripts/fel-boot.sh IMAGE_DIR elan standard`.
Use `diagnostic` for a diagnostic ZIP named
`pb626-elan-diag.dtb`/`pb626-megi-diag-initramfs.cpio.gz`.
The first local FEL prerequisite is `pb626-spl.bin`; the second is
`direct-entry.bin`. Both currently exist only in the developer's WSL lab:
`/root/pb626-lab`. These binary prerequisites are **not reproducibly built in
CI yet**, and the repository does not contain a complete replacement for
those two binaries.

The loader verifies the artifact SHA256SUMS, calls patched FEL `spl` once,
then writes and compares images in independent 64 KiB RAM transfers before
`execute`. This is intentionally slower but has been proven to transfer a
whole 6 MiB zImage without corruption over usbipd/WSL.

The USB gadget is a **new USB device** when Linux starts, not the FEL
interface. It may appear in Windows or WSL, so look in both places.
Without Linux VID:PID `0525:a4a7` or known Wi-Fi, there is no verified shell
connection; `sunxi-fel execute` returning success is not Linux boot proof.

All FEL operations must remain RAM-only. Never write the factory eMMC,
change the eMMC boot partition, or program the E Ink waveform SPI flash.