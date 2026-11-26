# PocketBook 626 Plus: observed hardware profile

Evidence: read-only [hardware inventory](../scripts/probe-device.sh) and KOReader SSH inspection of the owner's unit under stock firmware. Identifiers and raw device logs were intentionally
omitted. This is an observed firmware inventory, not confirmation that the
upstream Linux port operates all peripherals.

## Confirmed from the stock kernel

| Component | Observation |
| --- | --- |
| SoC | sun5i / Allwinner A13, ARMv7, CPU revision a13b |
| Kernel | 3.0.8-hg+default-c4548f764a28, built 2019-03-22 |
| Available RAM | 223036 KiB MemTotal; 51196 KiB swap (zram0) |
| Internal flash | /dev/mmcblk0, 7634944 KiB (7.28 GiB) |
| MMC hardware boot areas | /dev/mmcblk0boot0 and boot1, each 4096 KiB |
| Display | fb0, 758 x 1024 pixels, 8 bits per pixel |
| Touch input | elan-touchscreen (event2), I2C 2-0015 elan-ktf2k |
| Network | eth0, wireless via rtl8188eu |
| PMIC | axp20_mfd at I2C 0-0034 |
| RTC | pcf8563 at I2C 1-0051 |
| E Ink power supply | tps65185 at I2C 1-0068 |
| SPI | spi2.0 present |
| Power | battery and USB supply nodes reported |

A second read-only SSH inspection confirmed `/sys/block/mmcblk0/device/type`
reports `MMC`, with chip name `8WPD3R`. This confirms the internal eMMC
storage type. Its physical PCB revision remains unverified.

Stock U626.5.20.1157 exposes an unprivileged KOReader SSH account `reader` (UID/GID 101). Its SUID `sudo` is 1.7.4p6; the [Synacktiv command-path weakness](https://www.synacktiv.com/en/publications/e-ink-maiden-bring-your-reader-to-the-reverser.html) was not reproduced (calibrate denied). FEL recovery does not need stock root. Both hardware eMMC boot nodes report `force_ro=1`; this is a software safeguard, not an immutable region.

Observed filesystem mounts:
- `/dev/mmcblk0p2` at `/boot` (VFAT, read-only).
- `/dev/mmcblk0p8` at `/ebrmain` (ext2, read-only).
- `/dev/mmcblk0p9` at `/mnt/secure` (ext2, read-write).

The stock display uses the vendor framebuffer, not `/dev/eink-panel`. The secure partition can contain private device state; never publish its contents.


## Board wiring and revisions

The vendor image (kernel 3.0.8) has a single FEX covering several hardware
revisions. Its ctp_name=ft5x_ts at I2C2 0x24 is NOT the actual touchscreen on
every unit: p7/etc/init.d/rcS chooses a driver by hwconfig.app device_touchpanel.

| Stock touch type | Factory module | FEL board variant | New kernel status |
| --- | --- | --- | --- |
| 8: ELAN eKTF2227, I2C2 0x15 (observed late eMMC board) | ektf2k_elan.ko | elan-display / elan-emmc-native | Native port uses patched eKTF2227 protocol; hardware touch verified |
| 18: FocalTech FT5X / XC3 | ft5x_xc3.ko | not supported by current build | not qualified |
| 19: Cypress TMA4 / XD4, 0x24 | cyttsp4.ko | not supported by current build | not qualified |
| unknown | none | not a separate build | not qualified |

Common hardware from Megi DTS and the factory FEX:

| Device | Interface / GPIO | Linux support target |
| --- | --- | --- |
| Allwinner A13, 256 MiB | sun5i | CPU, DMA, CCU, regulators |
| External microSD | MMC0 PF0–PF5, PG0 card detect, PE4 active-low power | disabled (observed I/O stalls) |
| Internal eMMC (late), internal SD (early) | MMC2 PC6–PC11 | disabled in display RAM; enabled read-only in recovery; native root on MMC2 |
| ED060XD4-family 1024x758 E Ink | DEBE/TCON0 and PD GPIOs | Megi sun5i-eink V4L2 /dev/video0 |
| Panel power | TPS65185 I2C1 0x68, PD18 wake, PD19 VCOM, PE7 power, PE6 good | TPS65185 regulator |
| Panel waveform storage | SPI2 MX25U4033 in inherited Megi DT; physical NOR on this unit unconfirmed; vendor /boot/*.wbf | factory default.wbf supplied offline; SPI2 disabled in standard DTBs, diagnostic modules only |
| Touch input | I2C2 PB17/PB18, IRQ PG11, reset PB3, enable PE5 | patched ELAN eKTF2227 |
| Frontlight | PB2 PWM0, PB4 enable | pwm-backlight |
| Keys | GPIO PG9/PG10, LRADC Home/Menu | gpio-keys, sun4i-lradc-keys |
| Power LED | PE8 | gpio-leds |
| Main PMIC | AXP209 I2C0 0x34 | axp20x, battery and charging |
| RTC | PCF8563 I2C1 0x51 | rtc-pcf8563 |
| Wi-Fi | RTL8188EUS, internal USB host (VID 0bda PID 8179 on early board) | EHCI/OHCI, rtl8xxxu; firmware loading observed |
| USB gadget | OTG MUSB, serial CDC ACM | FEL RAM rescue and COM |

ELAN VCOM: factory /boot/vcom of this specific unit is -2440 mV.
The Megi TPS65185 driver takes a positive magnitude, so only the ELAN
variant overrides its voltage to 2440000 microvolts. Other revisions MUST
use their own measured panel values. Incorrect panel voltage or waveforms
can damage the display. Never embed factory waveform files, host SSH keys,
MMC IDs or user settings in the public repository.


Factory signed updates and board revision checks are separate from this native port. See [factory boot chain](STOCK-BOOT-CHAIN.md).

## Current hardware validation

- Late ELAN/eMMC: autonomous native Linux boot and USB ACM console verified.
- ED060XD4: monochrome, grayscale and partial updates verified with the
  original waveform and 2440000 uV VCOM magnitude. Manual refresh and touch
  verified on the previously installed renderer; current builds still require on-device acceptance.
- Frontlight: off and two brightness levels verified. PB4 enable is active
  high; keep PB2 disconnected from PWM while off. Stock PG1 VBUS sensing
  works under vendor Linux; modern MUSB enumerated after removing that GPIO
  from the peripheral-only DTB. This does not establish that PG1 is miswired.
- Wi-Fi: RTL8188EU VID:PID 0bda:8179; rtl8xxxu loaded uncompressed
  rtl8188eufw.bin revision 28.0 and created wlan0. Full networking and
  suspend/resume acceptance is incomplete.
- AXP209 battery/USB voltage/current and capacity exported; charger-only
  boot and suspend/resume not validated.
- External microSD I/O previously stalled; independent SD recovery failed.
  Current build disables MMC0. No independent recovery if SPL cannot enter FEL.
- GPU/Lima is not qualified and is disabled in the desktop.

Sources: https://linux-sunxi.org/PocketBook_Touch_Lux_3 ,
https://github.com/pocketbook/Platform_A13 ,
Megi board DTS pinned in the build workflow.
