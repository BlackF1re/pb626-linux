# Megi Linux 5.9 — PB626 board variants

The source of the complete baseline DTS, E Ink driver, TPS65185, Wi-Fi and
the kernel configuration is Ondrej Jirman's Touch Lux 3 port in the pinned
public fork: https://github.com/sailfish-on-dontbeevil/kernel-megi/tree/e98db7f114d7602c6b847d76e183787f0c97cf5b

The vendor image (kernel 3.0.8) has a single FEX covering several hardware
revisions. Its ctp_name=ft5x_ts at I2C2 0x24 is NOT the actual touchscreen on
every unit: p7/etc/init.d/rcS chooses a driver by hwconfig.app device_touchpanel.

| Stock touch type | Factory module | FEL board variant | New kernel status |
| --- | --- | --- | --- |
| 8: ELAN eKTF2227, I2C2 0x15 (observed late eMMC board) | ektf2k_elan.ko | pb626-elan.dtb | Experimental elants_i2c EKTH3500 binding; protocol may differ |
| 18: FocalTech FT5X / XC3 | ft5x_xc3.ko | pb626-focaltech.dtb | Experimental EDT FT5206 binding |
| 19: Cypress TMA4 / XD4, 0x24 | cyttsp4.ko | pb626-cypress.dtb | Megi's original early-board configuration |
| unknown | none | pb626-no-touch.dtb | Safe fallback with touch absent |

Common hardware from Megi DTS and the factory FEX:

| Device | Interface / GPIO | Linux support target |
| --- | --- | --- |
| Allwinner A13, 256 MiB | sun5i | CPU, DMA, CCU, regulators |
| External microSD | MMC0 PF0–PF5, PG0 card detect, PE4 active-low power | MMC sunxi; clock capped 12 MHz due to observed I/O stalls |
| Internal eMMC (late), internal SD (early) | MMC2 PC6–PC11 | DISABLED in all FEL variants; no flash writes |
| ED060XD4-family 1024x758 E Ink | DEBE/TCON0 and PD GPIOs | Megi sun5ieink; /dev/eink-panel requires waveform-aware userspace |
| Panel power | TPS65185 I2C1 0x68, PD18 wake, PD19 VCOM, PE7 power, PE6 good | tp65185x regulator |
| Panel waveform storage | SPI2 MX25U4033, PE0–PE3; vendor /boot/*.wbf | SPI NOR; waveform application not yet implemented |
| Touch input | I2C2 PB17/PB18, IRQ PG11, reset PB3, enable PE5 | Revision-specific DTBs, driver compatibility unverified |
| Frontlight | PB2 PWM0, PB4 enable | pwm-backlight |
| Keys | GPIO PG9/PG10, LRADC Home/Menu | gpio-keys, sun4i-lradc-keys |
| Power LED | PE8 | gpio-leds |
| Main PMIC | AXP209 I2C0 0x34 | axp20x, battery and charging |
| RTC | PCF8563 I2C1 0x51 | rtc-pcf8563 |
| Wi-Fi | RTL8188EUS, internal USB host (VID 0bda PID 8179 on early board) | EHCI/OHCI, r8188eu; not validated on this unit |
| USB gadget | OTG MUSB, serial CDC ACM | FEL RAM rescue and COM |

ELAN VCOM: factory /boot/vcom of this specific unit is -2440 mV.
The Megi TPS65185 driver takes a positive magnitude, so only the ELAN
variant overrides its voltage to 2440000 microvolts. Other revisions MUST
use their own measured panel values. Incorrect panel voltage or waveforms
can damage the display. Never embed factory waveform files, host SSH keys,
MMC IDs or user settings in the public repository.

The new workflow builds from ONE pinned 5.9 kernel source, not from
incompatible precompiled Linux 7.x modules. The image is for FEL + external
microSD only. E Ink updates, ELAN and FocalTech protocols, frontlight,
Wi-Fi and suspend remain hardware acceptance tests, not guaranteed features.

Sources:
- https://linux-sunxi.org/PocketBook_Touch_Lux_3
- https://github.com/pocketbook/Platform_A13 (missing factory epdc.ko source)
