# pb626-linux

Alternative Linux for PocketBook 626 Plus / Touch Lux 3 (Allwinner A13).
**Development boot is FEL → RAM kernel → external microSD Alpine. The factory
8 GB eMMC must never be modified by experimental builds.**

## What already worked on the device

- FEL entry with the far-right Menu button, kernel in RAM and Alpine rootfs
  on microSD; USB gadget COM console, Wi-Fi, SSH and `apk`.
- Problems to solve: intermittent microSD I/O stalls / interrupted ext4 journal,
  no E Ink refresh, frontlight stuck at maximum, and wrong Cypress touchscreen
  description (the actual hardware uses ELAN at I2C 0x15).

The supplied local Linux 7.1.3 configuration has `CONFIG_FB_SUN5I_EINK=m`
while `CONFIG_MEDIA_SUPPORT` is disabled. A separate, later experimental
`sun5i-eink.c` source uses V4L2. They are **not the same display path**:
loading a kernel module alone cannot display a Linux console or GUI.

## Build and bootstrap

- **GitHub Actions → FEL board DTB:** compiles `board/pb626-sd-fel.dts` and checks
  that internal eMMC and the mismatched Cypress touchscreen are both disabled.
  This variant is **not boot-tested**. The external MMC clock is capped at
  12 MHz until its stability is resolved.
- **GitHub Actions → ARMv7 userland:** downloads, verifies and QEMU-tests the
  Alpine bootstrap archive. This is not a complete boot image.
- `scripts/fel-boot.sh` replays the previously used RAM-only USB loader with
  already-built lab inputs. It still relies on files in `/root/pb626-lab`:
  `pb626-spl.bin`, `fel-kernel.zImage`, `direct-board.dtb`,
  `direct-initramfs.cpio.gz`, `direct-entry.bin` and `sunxi-fel`.
- `scripts/inspect-live.sh` reads E Ink, PWM, backlight and MMC diagnostics
  from the *alternate Linux*. It does not change hardware settings.

**Do not flash** any provided artifact. In particular, never execute a generic
SD-card writer against an unverified `/dev/sdX` or the eMMC. The source
`boot/init` defaults to a read-only microSD root; writable mode requires an
explicit `pb626.root_rw=1` kernel argument *after an offline filesystem check*.

`kernel/linux.config` and `boot/` are imported starting points from the
previous lab. They are not a complete reproducible kernel build: the exact
working kernel source, its out-of-tree patches, the FEL entry assembly and
boot-stage sources still need to be identified. No need to replace stock
firmware, gain stock root or open the reader to continue development.
