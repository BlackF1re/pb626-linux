# Experimental cold-boot isolation (PocketBook 626 Plus)

## What is confirmed

- On the observed ELAN unit, Megi 7.2 + Alpine boots using USB FEL.
- The same kernel and userspace can mount the installed Alpine eMMC p1 root
  filesystem read/write when FEL starts the kernel.
- Factory BT0, BT1, and boot.axf can load code from FAT p2, according to
  the owner's reverse-engineered boot-chain notes.
- Earlier U-Boot testing left a post-`bootz` marker. Without a UART log,
  that observation alone cannot distinguish a rejected image from an
  immediately returning or failed handoff.
- The source currently has no confirmed cold-boot kernel log.

## Independent path to test

The `axf-chainload.yml` workflow builds a **standalone** Megi U-Boot binary,
not `u-boot-sunxi-with-spl.bin`, and extracts two separate payloads from a
matching kernel-bundle artifact:

- `linux/u-boot.bin`: linked for execution at `0x4a000000`.
- `linux/pb626-zImage`: loaded by U-Boot at `0x42000000`.
- `linux/pb626.dtb`: loaded by U-Boot at `0x43200000`.

This path intentionally has **no initramfs**, because the target eMMC p1
already contains a working Alpine root with `/sbin/pb626-emmc-init`. The DTB
removes initrd address properties. Built-in MMC and ext4 support are asserted
by the main kernel build.

**Do not write these files until the Actions build succeeds and the current
device's original p2 files and every eMMC area are backed up and verified.**

For a *test copy* of `linux.ini`, the documented boot.axf interface is:

```ini
[segment]
img_name = c:\linux\u-boot.bin
img_size = 0x80000
img_base = 0x4a000000
```

This configuration is an experimental adaptation of the generic
[linux-sunxi boot.axf documentation](https://linux-sunxi.org/Boot.axf);
it is **not proven** on this PocketBook. Preserve the original non-segment
configuration fields and factory recovery INIs. The workflow deliberately
does not flash, partition, overwrite, or remotely install anything.

## Diagnostic order

1. Check the rebuilt `u-boot.bin` size and `.config` and preserve the
   immutable bundle plus checksums.
2. Before any install, inspect the actual original `linux.ini` and
   `normal.ini` byte-for-byte, including line endings and all sections.
3. Before booting, verify that the eMMC p1 root has an executable
   `/sbin/pb626-emmc-init`. Check its interpreter and required libraries.
4. Perform the standalone AXF-to-U-Boot boot test only after recovery is
   proven. On failure, use FEL to restore the original p2 configuration.
5. If no USB or LED heartbeat appears, add independent persistent stage
   diagnostics at U-Boot entry, before `bootz`, and after a returned
   `bootz` command. Do not interpret USB silence alone as proof of failure
   in the first-stage loader.

## Important remaining unknowns

- Whether this unit's factory boot.axf accepts the standalone U-Boot binary
  and configuration without any changes to other boot INI sections.
- Whether U-Boot's MMC numbering sees eMMC as device 0, 1 or 2.
- Whether the initial stack, caches and CPU clocks supplied by factory
  boot.axf are sufficient for this Megi U-Boot.
- Whether the current rootfs image and DTB remain compatible with direct
  mounting when no initramfs is present.
- Whether the LED observation accurately reflects the exact pre-kernel stage.

Never infer a successful kernel boot from the factory frontlight LED pattern.
