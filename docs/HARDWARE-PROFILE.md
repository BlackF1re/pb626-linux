# PocketBook 626 Plus: observed hardware profile

Evidence: first read-only KOReader SSH inventory of the owner's unit, collected
under stock firmware. Identifiers and raw device logs were intentionally
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
| Power | battery and USB supply nodes reported; 85% battery at probe |

A second read-only SSH inspection confirmed `/sys/block/mmcblk0/device/type`
reports `MMC`, with chip name `8WPD3R`. This confirms the internal eMMC
storage type. Its physical PCB revision remains unverified.

The reader SSH account is `reader` (UID/GID 101); no privileged access was
established by this inspection. Follow-up diagnostics confirm that stock
`sudo` is version 1.7.4p6, with SUID-root permissions. Its `sudo -l`
allow-list matches the one analyzed by Synacktiv on Touch Lux 3, including
`/bin/set_bootmode calibrate` and a passwordless `sshstart.sh` entry.
Synacktiv documented a command-path validation weakness in this configuration:
https://www.synacktiv.com/en/publications/e-ink-maiden-bring-your-reader-to-the-reverser.html

The root execution path is **not yet validated on this physical unit**.
Do not treat presence of sudo or the matching allow-list as confirmed
privileged access. A temporary, non-persistent proof of `id` must precede
any raw-device backup or firmware change. The kernel reports `force_ro=1` on both eMMC
hardware boot devices. This is a software read-only safeguard, not evidence
that the contents are immutable or that the active boot source is known.

Observed filesystem mounts:
- `/dev/mmcblk0p2` at `/boot` (VFAT, read-only).
- `/dev/mmcblk0p8` at `/ebrmain` (ext2, read-only).
- `/dev/mmcblk0p9` at `/mnt/secure` (ext2, read-write).

The reported mount mode does not by itself establish which files the
unprivileged SSH account may change. Do not publish raw contents of
`/mnt/secure`; it may contain device-specific or private state.

The stock firmware uses a vendor framebuffer; no `/dev/eink-panel` node was
observed. This says nothing about whether a replacement kernel can expose the
out-of-tree E Ink API.

## Revision and mainline compatibility

- The upstream PocketBook Touch Lux 3 device tree enables a non-removable
  `mmc2` and marks I2C2 as containing the touchscreen, but **does not**
  instantiate a touchscreen child device:
  https://code.googlesource.com/linux/torvalds/linux/+/refs/heads/master/arch/arm/boot/dts/allwinner/sun5i-a13-pocketbook-touch-lux-3.dts
- Community evidence associates ELAN KTF2K with later PB626 revisions
  (v1.9/v2.1), in contrast with early Cypress/FocalTech boards. This is a
  useful hypothesis, **not a verified PCB version**:
  https://www.mobileread.com/forums/showthread.php?p=4526183
- The generic upstream `elants_i2c` driver exists, but compatibility with
  this vendor `elan-ktf2k` controller, power sequencing, GPIO reset/IRQ,
  calibration and runtime suspend remains unverified:
  https://github.com/torvalds/linux/blob/master/drivers/input/touchscreen/elants_i2c.c

Do not silently select early-revision Cypress-specific configuration for
this hardware. First obtain a board revision, touchscreen pinout and a boot
log from the replacement kernel when non-destructive booting becomes possible.

## Next inspection (read-only)

Via the established KOReader SSH connection, check the account privilege
level, MMC media type, boot-area config and which volumes are mounted.
Do not dump MMC CID/CSD, serials, MAC addresses, authentication data or
complete kernel logs into a public repository.

No image should be flashed until the boot chain and a verified recovery path
are documented. Restoring only `mmcblk0p1` is not an adequate factory backup.
