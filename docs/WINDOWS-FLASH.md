# PB626 Windows firmware console (x64 candidate)

Windows 10 and 11 x64, built-in Windows PowerShell 5.1. No WSL, Python
installation, MSYS2, usbipd, or third-party Ethernet tools on the user's
PC. Extract the entire `pb626-windows-flash-kit` artifact on a local
NTFS disk, double-click PB626.cmd and accept the administrator prompt.
Use the known late ELAN/eMMC model only. The native Windows USB path
requires physical qualification; CI only checks compilation and mock/
offline behavior.

## First use

1. Select an operation. Default install writes p1 and its paired
   kernel/DTB, retaining a recognized installed uncaged BT0. It erases
   all native rootfs user files, so back up first. Qualified installation
   can also reconstruct the exact historical BT0. Do not use "keep"
   when still running factory BT0.
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
   new Linux root password and confirm the displayed CID. Every
   written chunk is synced, relocked and read back with SHA256.
   Rootfs first, kernel/DTB second, BT0 last only if requested.
   No automatic retry after a failed write.

## Operations

- Install: paired Debian rootfs + kernel, preserve recognized BT0.
- InstallQualified: same payload plus historical hash-qualified BT0.
- InstallCandidate: same payload plus new **experimental** source BT0
  with LED animation. Requires a complete verified backup for the same
  CID, an exact same-run recovery authorization, and extra confirmations.
- Bootloader / RestoreBootloader: write just LBA 16–63 (24 KiB), leaving
  rootfs, kernel and all other sectors unchanged. Experimental option
  has the same backup and confirmation gates.
- Backup / Restore / Preflight: existing full eMMC dump format, including
  hardware boot regions and EXT_CSD verification. Restore is destructive.
- Recovery: verified RAM-only boot; no writes.
- Validate / Prepare: offline package check / prepare FEL inputs.

Examples from Windows PowerShell 5.1:

    .\PB626.ps1 -Action Validate
    .\PB626.ps1 -Action Install
    .\PB626.ps1 -Action Backup -DataDir D:\PB626
    .\PB626.ps1 -Action Recovery -UsbProfile RNDIS

The experimental BT0 may break Menu/FEL. A backup is not a substitute
for an independent physical recovery route. Do not install it until you
accept that risk. The ordinary Windows bundle does not flash the isolated deep kernel or
retained-DRAM SPL. It keeps production sleep policy and module
compatibility. The separate `pb626-windows-deep-lab-EXPERIMENTAL` artifact
from full qualification has the same launcher, but only the explicit
InstallDeepLab option writes its paired deep kernel, matching modules
inside the rootfs, and deep-resume SPL last. It requires a full verified
backup and the same risk confirmations. It still leaves systemd's
s2idle default and the suspend-qualified gate untouched. Do not mix a
lab zImage with production rootfs modules or try deep until physical
cold boot and Menu/FEL have been checked repeatedly.

Native FEL source: pinned linux-sunxi/sunxi-tools commit
0237931bb3d66de17c441a3c94d0e4b39e1308d1 with the existing lab MMU patch;
corresponding source is included in host/. Python is the pinned official
embeddable distribution. MSYS2 UCRT64 packages are used only in CI.
Zadig is an optional separately downloaded application (GPL; source at
https://github.com/pbatard/libwdi/tree/v1.5.1); it installs Microsoft's
WinUSB driver for FEL, not a replacement for sunxi-fel.

The menu accepts 0 to cancel and invalid selections can be corrected.
The launcher offers to reuse an existing same-build recovery. A session
record in private/sessions marks the latest potentially destructive write
before transmission; no passwords or payloads are logged. Progress reflects
acknowledged blocks. After a failed write keep the book powered; do not
reboot or retry SPL automatically. Use -BackupDir to supply a verified dump.

BT0-only operations additionally verify the installed raw kernel byte for
byte against this kit, mount p1 read-only without journal replay, and
check the native image ID, matching module release and waveform. If the
reader still runs factory firmware or another kernel, install the paired
kernel/rootfs first. This restriction is intentional: a BT0-only operation
must not replace the stock boot chain while leaving stock payloads in place.

## Partial updates and interruption recovery

Standard bundles add RootfsOnly (requires exact installed raw kernel),
KernelOnly (requires exact installed module-tree manifest), and ResumeBackup.
Deep lab retains the explicit all-component pair restriction. RecoveryTest
checks same-run identity, random RAM transfer, CID, layout, EXT_CSD and
read-only 4 MiB samples of user/boot0/boot1. No destructive self-test.

If TCP is interrupted, choose R to reconnect to running recovery; F is
only for a reader that already lost power. Do not deliberately power-cycle
a partially flashed reader. The same session pins CID, operation and input
manifest. Each firmware or restore chunk is compared to actual eMMC data;
matching chunks are skipped, even if the final acknowledgement was lost.
A rootfs install may redo changed personalization metadata and requires the
root password again. Partial backup files are synced per chunk and checked
against live hashes before reuse. ResumeBackup accepts an incomplete dump
folder; a SHA256SUMS completion marker is written only after all regions
are verified. A validation/hash failure is not automatically retried.
