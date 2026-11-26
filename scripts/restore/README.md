# eMMC backup and restore: format and safeguards

**[Step-by-step Windows instructions](https://github.com/BlackF1re/pb626-linux/blob/main/docs/INSTALL.md)**

Use the tested ELAN / Samsung 8WPD3R board with recovery variant elan-emmc-backup. The eMMC is read-only and unmounted until an explicit restore. PowerShell 7.4+ and all files from pb626-emmc-tools are required. Verify the tool artifact's SHA256SUMS; older artifacts provide SHA256SUMS.fast for the ARM helper only. The new backup receiver and CID adaptation still need physical validation; the original differential restore was hardware-tested. The backup receiver uses one raw SerialPort BaseStream for both line framing and binary payloads, avoiding text-reader prefetch across a binary frame.

## Backup format

All files are required in a private directory:

| File | Contents |
| --- | --- |
| pb626-emmc-user.img | 15,269,888 sectors × 512 bytes |
| pb626-emmc-boot0.img / pb626-emmc-boot1.img | 8192 sectors × 512 bytes each |
| pb626-emmc-ext-csd.bin | 512-byte EXT_CSD snapshot |
| pb626-emmc-cid.txt | Original card CID |
| SHA256SUMS | SHA-256 of all files |

A partial backup has no final manifest and is not restorable. The backup verifies each 4 MiB block and compares full local files against independent device hashes. The restore preflight checks image sizes, hashes, CID, geometry, EXT_CSD configuration, unmounted/read-only status and a RAM USB transfer. Write requires -Write and the exact RESTORE CID confirmation.

Only differing blocks are written (gzip if smaller); each payload is verified before enabling writes. Regions are relocked and all three full readback hashes must match before power-off. EXT_CSD is checked, not programmed; RPMB and other hardware-specific state are not cloned. Recovery independent of a working FEL entry is unproven.

Legacy backups without a CID file require -ExpectedCid ORIGINAL_CID. -AllowOtherCard overrides CID only and copies device-specific data; it is unsupported on unverified boards. Never bypass geometry, identity or checksum failures.

Do not publish dumps, CID, credentials or proprietary calibration.
