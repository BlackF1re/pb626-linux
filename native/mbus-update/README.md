# Known-image MBUS update (already installed native system only)

Preserves the physically exercised v2 update procedure. The repository version
requires an explicit owner-supplied CID instead of embedding a device identifier,
uses the shared serial transport, and requires an independently held full
rollback image for writes. These adaptations have not been re-tested on hardware.
This is not a general or fresh-device installer. No images or backups are stored
here. See [validation record](../../docs/NATIVE-BOOT-MBUS.md).

The exact images must be sourced locally and independently checked. Existing
old and new kernel module directories must both be present. Before Install,
boot the exact new image via FEL with the persistent root, confirm the desktop
and touch, and verify the full old extent. Do not reinstall BT0. Status does
not write raw eMMC; Install and Rollback write only the verified extent.
No power-loss protection is guaranteed. Keep independent recovery and backups.

From Windows PowerShell in the repository, use install.ps1 with -Mode Status
-ExpectedCid <owner CID> -Port COM13. Install additionally needs -NewImage
and -RollbackImage, and Rollback needs -RollbackImage. Check exact success
markers, then Status again before poweroff. An unexpected check failure is a
stop condition, not a reason to weaken the checks. Never put CID or backups in Git.
