# eMMC backup and restore

Only for the tested late ELAN / Samsung 8WPD3R board, 512-byte sectors,
15,269,888 user-area sectors and two 8192-sector boot areas. Power off and
enter cold FEL with Menu while attaching USB. Boot the matching RAM recovery
bundle, not the native Linux filesystem:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FEL\Start-PB626.ps1 -BundleDir .\FEL -Variant elan-emmc-backup -Profile diagnostic

The recovery image starts with all MMC nodes read-only and no mounted
partitions. Find the current VID:PID 0525:a4a7 COM port and close PuTTY.
Use PowerShell 7.4 or newer. Download the matching pb626-emmc-tools CI
artifact and keep all its files together. The FEL bundle and private dumps
remain separate. See the repository README for local FEL dependencies.

Backup (new directory; does not write eMMC):

    .\Backup-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\backup

All three raw regions, a 512-byte EXT_CSD snapshot, original CID and SHA256SUMS
are saved. Each 4 MiB read is verified and the full local files are compared
against fresh device hashes. A partial/incomplete directory lacks the final
manifest and is not restorable. The new host receive path is not yet
hardware-validated; preserve your already verified original dumps.

Restore preflight, then explicit destructive write:

    .\Restore-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\backup
    .\Restore-PB626Fast.ps1 -Port COM12 -BackupDir C:\PB626\backup -Write

For an older backup without pb626-emmc-cid.txt supply -ExpectedCid with the
ORIGINAL backup card's CID in both calls. Do not use the current card's CID
unless it is the original. -AllowOtherCard explicitly overrides matching
CID only; never bypass geometry, model, read-only, EXT_CSD or checksum
checks. Different-card restores copy device-specific factory data and are
not supported on an unverified board.

Type RESTORE <CID> when requested. Wait for
All three eMMC regions match SHA256SUMS before powering off.
The helper compares 4 MiB blocks, transfers only different blocks (gzip
when beneficial), verifies hashes before opening a region for writes,
relocks it and verifies full readback. The EXT_CSD is recorded/checked,
not programmed. RPMB and other hardware-specific state are not cloned.
No recovery if BootROM cannot be reached is established.

The original restore implementation was used on hardware by the owner.
Externalizing its original CID and the new backup path still need device
validation. Never publish a dump, CID, device credentials or calibration.
