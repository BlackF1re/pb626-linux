# Native boot consolidation — physical validation, 2026-11-25/26

Scope: one late ELAN/eMMC A13 reader, 256 MiB. Main already contains the
fast BT0 hook, Fast Wrapper, built-in E Ink and the MBUS device-link fix
(PR #11), and indexed renderer as the default. This change preserves the
native runtime sources from native-boot (a032f5d14c6fedac138418a3c9cd1281f5a00a1a)
without restoring the obsolete factory FAT/AXF installer or replacing RAM workflows.
The native desktop explicitly selects indexed, as tested with the installed
older worker. No fixed startup delay, no preclear experiment, no Lima.

## Observed results

| Event (kernel-relative) | Old native | MBUS-fixed cold native |
|---|---:|---:|
| E Ink driver ready | 13.286 s | 0.821 s |
| eMMC detected | 0.926 s | 0.936 s |
| PID 1 | 1.490 s | 1.503 s |
| CRNG ready | 12.214 s | 2.152 s |

Operator-reported end-to-end boot ~69 s original, ~22 s after accelerated BT0
and wrapper, ~12 s after MBUS update. Not an isolated BT0 measurement.
The new kernel first ran from FEL RAM with the existing ext4 root and staged
modules; then the raw extent was replaced and readback-verified. Cold Power
boot reached the desktop. Indexed profile (interval 11, 81 RESET and 40 FULL
scans): first acknowledged frame 5.962 s, last startup update 7.022 s;
scalar 6.183 s / 7.244 s. The fixed 500 ms desktop-first experiment was worse
(6.359 s / 7.419 s), so it is excluded.

## Exact tested identities

Kernel release: 7.2.0-pb626-eink-builtin-mbusfix-gfacc87117511-dirty.
RAM bundle workflow run 45652569447, artifact 15042156293.
zImage SHA256 aaaa131a34bca28a2f815b2af583ad02f1007dcfde1d6a1ff5d5acda49bde4f9
(native input is the bundle's padded zImage).
Native DTB SHA256 351d15522cb4bdbca2b2edc14a64e2c48396810cf882279fa51eff302a75e958.
New raw image SHA256 33380f0bf21a7ba8b0480d7c545609bf0c05b9b5999c8bf3cced9dd16283384e.
14959 sectors, payload 7658540 bytes; LBA 80–15038 inclusive.
Previous raw image 14894 sectors SHA256 ff11503fa46198e1175fac659fcfaa354bc2f01fbe1861677468fc6440b9de7c.
Full rollback extent (14959 sectors, includes 65 extra zero sectors) SHA256
5f98e5c1b946ef50e9331074494191f6df5b3f662be28b627ea184598538e301.
Protected prefix LBA 0–79 SHA256 2673c7b186a731b8b429812f4d55340c054fbbd5c42e0582b3a06794e12e8b63.
Both BT1 extents LBA 38192 and 38704, 448 sectors each, SHA256
3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227.
No device CID, backups, proprietary waveform or binary factory data are committed.

## Native runtime contract

The retained board fragment is composed after elan, elan-display and
elan-ektf2227. MMC2 enabled at 25 MHz, MMC0 disabled, no initrd,
root=/dev/mmcblk2p1 rootfstype=ext4 rootwait rw init=/sbin/init.
Keep the tested per-device DTB and calibration for a kernel-only update.
The fragment is source retained from the earlier native branch, not a claim
that rebuilding it with the current toolchain reproduces the historical DTB
byte for byte. RAM variants must remain separate from native DTBs.

On an already prepared native root, boot/pb626-native-{setup,desktop,console}
are /sbin/pb626-native-{setup,desktop,console}, and
boot/pb626-native.inittab is /etc/inittab. Existing image ID:
pb626-native-alpine-v1. The local root ACM console is deliberately unauthenticated
on physically connected USB; this is lab firmware, not a production security
configuration. The factory WBF is supplied by the owner at
/lib/firmware/pb626/default.wbf. No automatic root filesystem installation is
enabled by this PR.

## Kernel-only update contract

Stage matching modules in a separate release directory; retain old modules.
Verify SHA256 manifest and module archive paths. Pack verified zImage and
native DTB with BT0-uncaged/pack-kernel.py; compare the resulting raw hash and
size to the tested identity above for that exact input. Boot the payload from
FEL before persistent changes; check native root, Xorg, renderer, touch and
the expected release. No raw write during the FEL test.

Before any persistent write, verify device identity against an explicitly
supplied owner CID, 512-byte sectors, root mount, image ID, p1/p2 geometry,
all real partition boundaries, prefix and both BT1 checksums, and exact
full old extent. The known MBR extended partition p3 starts at LBA 1 and
Linux exposes it with size 2; it is not a data partition. Exempt only that
exact representation after verifying the pinned MBR/EBR-containing prefix.
Persist an independently verified full rollback copy outside the region
to be written, also keep the off-device copy. Write only LBA 80–15038,
sync, read back and verify the new extent and protected regions. On failure
do not reboot; restore the prior extent while Linux is running and verify it.
Neither power-loss safety nor independent recovery when SPL fails is proven.

The one-device update scripts were exercised outside Git; the original
backup and hardcoded device-specific material are intentionally not included.
See the known-image updater in this PR if present; it is not a fresh-device
installer. Never apply this layout to an unverified revision.
