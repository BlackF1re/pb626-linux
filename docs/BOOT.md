# Current boot chain and validation

BootROM -> BT0-uncaged (24 KiB in eMMC User Area LBA 16–63)
-> legacy uImage at LBA 80 -> wrapper at 0x40008000
-> zImage at 0x46000000, DTB at 0x47000000 -> native Alpine p1 ext4.
The SPL initializes DDR3 and MMC2 at 25 MHz, with at most 4096 sectors
per read. Its early Menu hook polls LRADC with bound 0x80000; a cold
Menu press can return to FEL. Factory BT1 and boot.axf are not executed.
Preserve them and the factory partition layout in offline backups.

Native DTB: MMC0 disabled, MMC2 enabled, no initrd,
root=/dev/mmcblk2p1 rootfstype=ext4 rootwait rw init=/sbin/init.
Runtime scripts in boot/ configure proc/sys/dev/run, disable frontlight,
start USB ACM and the desktop independently. A persistent E Ink worker
starts before xinit; INIT overlaps Xorg startup, and its ACK is required
before skipping the first physical reset. No GUI-specific readiness gate.
The renderer's ready file indicates first acknowledged frame, not all
icons or widgets settling.

## Hardware observations

| Event | Observation |
|---|---|
| Original native boot | ~69 s end-to-end |
| Fast wrapper/SPL | ~22 s end-to-end |
| MBUS correction | ~12 s end-to-end |
| Persistent Generic | 4.863 s to first frame relative to kernel |
| Persistent Generic | 5.697 s upper desktop DU ACK; 6.555 s final startup GL16 |

End-to-end times are operator estimates, not calibrated stopwatch tests.
Kernel-relative timing is one hardware profile on the installed system,
not a controlled benchmark. Exact tested Persistent Generic source
9802a3f6435a5940ca6b8e44f2b4d200d3eca7b2; Actions run 45675934476,
artifact 15050903994. One RESET (81 scans), first FULL (40 scans), later
three DU and GL16. The post-startup icon-completeness interpretation is
based on damage coordinates. Consolidated source/build is a new revision,
not an assertion of bit-identical binaries or an independently validated
fresh installation. Historic measurements and variants: PR #13.

## Why MBUS patch is retained

With permissive links, initial regulator acquisition correctly returned -EPROBE_DEFER at 0.102355 s; successful probe preceded PID 1 at 2.039911 s. At 2.07 s during an unmodified-command-line audit boot, debugfs devices_deferred reported:

    1c0c000.display-controller      platform: supplier 1c01000.dram-controller not ready

The MBUS link was dormant; TPS65185 and pinctrl links were available. The MBUS platform device has no bound driver. The DT interconnects/dma-mem pair is required by __of_get_dma_parent() for DMA address translation. CONFIG_SUNXI_MBUS=y provides a bus notifier, not a platform driver for this node; CONFIG_INTERCONNECT is disabled.

The local patch suppresses only automatic firmware device links for the A13 MBUS dma-mem entry when CONFIG_INTERCONNECT is disabled. It keeps the properties, DMA mapping, other links, regulator checks, global timeout and fw_devlink default intact. It does not write hardware registers. The new kernel release suffix prevents mixing modules with previous builds.


Hardware verified after the fix: native video0 at 0.821 s instead of
13.286 s, PID1 at 1.503 s, CRNG at 2.152 s. Physical scanout and cold
native boot succeeded. Keep the DMA properties; do not globally disable
firmware device links.

## Exact tested identities

Kernel release: 7.2.0-pb626-eink-builtin-mbusfix-gfacc87117511-dirty.
RAM bundle workflow run 45652569447, artifact 15042156293.
zImage SHA256 aaaa131a34bca28a2f815b2af583ad02f1007dcfde1d6a1ff5d5acda49bde4f9
(native input is the bundle's padded zImage).
Native DTB SHA256 351d15522cb4bdbca2b2edc14a64e2c48396810cf882279fa51eff302a75e958.
New raw image SHA256 33380f0bf21a7ba8b0480d7c545609bf0c05b9b5999c8bf3cced9dd16283384e.
14959 sectors, payload 7658540 bytes; LBA 80–15038 inclusive.
Protected prefix LBA 0–79 SHA256 2673c7b186a731b8b429812f4d55340c054fbbd5c42e0582b3a06794e12e8b63.
Both BT1 extents LBA 38192 and 38704, 448 sectors each, SHA256
3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227.
No device CID, backups, proprietary waveform or binary factory data are committed.


## FEL rescue

Cold Menu + USB yields 1f3a:efe8. A patched sunxi-fel initializes DRAM once
and verifies 64 KiB writes/readbacks. The 52-byte entry at 0x41000000 passes
zImage 0x42000000 and DTB 0x43200000; initramfs starts at 0x45000000.
The DTB describes RAM 0x40000000–0x50000000 and exact initrd bounds.
Linux enumerates as 0525:a4a7; execute return alone is not proof of boot.
See [installation guide](INSTALL.md) for prerequisites. Never execute a native DTB via the RAM loader. Independent recovery when SPL itself fails is unproven.

## Installing and recovery

Use the [offline installer and FEL backup/restore](INSTALL.md). Never write a live mounted native root.
