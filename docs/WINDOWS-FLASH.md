# PB626 Windows firmware console (x64 candidate)

Windows 10 and 11 x64, built-in Windows PowerShell 5.1. No WSL, Python
installation, MSYS2, usbipd, or third-party Ethernet tools on the user's
PC. Extract the entire `pb626-windows-installer` artifact on a local
NTFS disk, double-click PB626.cmd and accept the administrator prompt.
Use the known late ELAN/eMMC model only. The native Windows USB path
requires physical qualification; CI only checks compilation and mock/
offline behavior.

## First use

1. Select Install to write p1, the paired kernel/DTB, and the resume-capable
   BT0. It erases native rootfs user files, so preserve data first. The
   bootloader update is bound to the same-run recovery image and model report.
2. The historical FEL-only SPL is fetched directly from its original
   author with both combined-image and SPL SHA256 checked. If unavailable,
   place your verified `uboot.bin` or `pb626-spl.bin` in `fel-inputs`.
   It is not redistributed by CI. The entry stub and patched native
   sunxi-fel.exe are bundled.
3. Power the reader completely off, unplug it, hold Menu, then connect
   USB. If FEL does not respond, the console offers Zadig 2.9. The
   official download is checked against SHA256
   4ecaa95df3da3621486a043aef8b3050b8bafe7c901402871e816229ef82039b.
   You may instead place that exact copy of zadig-2.9.exe beside PB626.cmd.
   In Zadig, choose Options > List All Devices, select only USB ID
   **1F3A:EFE8**, choose WinUSB and install the driver. Do not replace
   any other USB device or the recovery Ethernet/ACM driver.
   If Windows binds the NCM parent (0525:A4A7) to ELMO GMAS or another
   COM-port driver, manually select USB Composite Device via Device
   Manager > Update driver > Have Disk > C:\Windows\INF\usb.inf.
   Keep the reader powered; then use -UseRunningRecovery. Do not remove
   unrelated driver packages. RNDIS is an alternative after cold power-off.
4. FEL initializes DDR once and verifies kernel, DTB, initramfs and
   entry in 64 KiB RAM chunks before execution. Do not retry SPL in
   the same power cycle. On Windows 11 use inbox USB NCM; on Windows
   10 use the separate RNDIS recovery DTB (automatic OS selection).
   Override with -UsbProfile NCM or RNDIS if necessary. Both profiles
   preserve the emergency ACM console. The launcher configures only
   the matching USB adapter at 169.254.62.2/30, verifies the recovery
   handshake, and removes the temporary address on exit. No firewall
   exceptions, default routes or Internet sharing are created.
5. The installer validates the model, CID, partition layout, random
   4 MiB TCP transfer, waveform, VCOM and sleep artwork; enter a
   new Linux root password (minimum four characters) and confirm the operation with y (default: cancel). Every
   written chunk is synced, relocked and read back with SHA256.
   Rootfs first, kernel/DTB second, BT0 last only if requested.
   No automatic retry after a failed write.

## Operations

- Install: paired Debian rootfs, kernel/DTB, modules and resume bootloader.
  A complete same-CID backup is optional; pass -BackupDir to verify it.
  Without a backup the installer requests explicit final confirmation.
- Backup / Restore / Preflight: existing full eMMC dump format, including
  hardware boot regions and EXT_CSD verification. Restore is destructive.
- Recovery: verified RAM-only boot; no writes.
- RecoveryTest: same-run identity, RAM transport, CID, layout, EXT_CSD and
  read-only storage sampling.
- ResumeBackup: continue an incomplete backup.
- Validate / Prepare: offline package check / prepare FEL inputs.

Examples from Windows PowerShell 5.1:

    .\PB626.ps1 -Action Validate
    .\PB626.ps1 -Action Install
    .\PB626.ps1 -Action Install -BackupDir D:\PB626\backup-verified
    .\PB626.ps1 -Action Backup -DataDir D:\PB626
    .\PB626.ps1 -Action Recovery -UsbProfile RNDIS

The resume bootloader and kernel are installed together. Isolated BT0,
kernel or rootfs updates are not enabled for this package. A BT0 update
can prevent Menu/FEL; a backup is not a substitute for independent
physical recovery. Verify cold boot and Menu/FEL repeatedly. Suspend
uses deep mode once the existing hardware qualification marker is set.

Native FEL source: pinned linux-sunxi/sunxi-tools commit
0237931bb3d66de17c441a3c94d0e4b39e1308d1 with the existing lab MMU patch;
corresponding source is included in host/. Python is the pinned official
embeddable distribution. MSYS2 UCRT64 packages are used only in CI.
Zadig is an optional separately downloaded application (GPL; source at
https://github.com/pbatard/libwdi/tree/v1.5.1); it installs Microsoft's
WinUSB driver for FEL, not a replacement for sunxi-fel.

The menu accepts 0 to cancel and invalid selections can be corrected.
With the automatic USB profile, the launcher reuses an existing recovery adapter and checks the exact build before proceeding. Use -UsbProfile NCM or RNDIS to explicitly cold boot, or -UseRunningRecovery to skip FEL. A session
record in private/sessions marks the latest potentially destructive write
before transmission; no passwords or payloads are logged. Progress reflects
acknowledged blocks. After a failed write keep the book powered; do not
reboot or retry SPL automatically. Use -BackupDir to supply a verified dump (recommended); without it the final confirmation explicitly warns that no backup is present.

## Interruption recovery

RecoveryTest checks same-run identity, random RAM transfer, CID, layout,
EXT_CSD and read-only 4 MiB samples of user/boot0/boot1. No destructive self-test.

If TCP is interrupted, choose R to reconnect to running recovery; F is
only for a reader that already lost power. No extra typed risk phrase is needed. Do not deliberately power-cycle
a partially flashed reader. The same session pins CID, operation and input
manifest. Each firmware or restore chunk is compared to actual eMMC data;
matching chunks are skipped, even if the final acknowledgement was lost.
A rootfs install may redo changed personalization metadata and requires the
root password again. Partial backup files are synced per chunk and checked
against live hashes before reuse. ResumeBackup accepts an incomplete dump
folder; a SHA256SUMS completion marker is written only after all regions
are verified. A validation/hash failure is not automatically retried.
