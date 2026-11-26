# PB626 Debian flash kit (candidate)

One artifact, `pb626-debian-flash-kit`, contains the same-run native
Debian system, minimal RAM recovery, host backup/restore tools, offline
assembler and entry points. It does not contain any private factory
data, password, or the unrecovered private SPL inputs.

Supported hardware: late ELAN/eKTF2227, 8WPD3R eMMC and the validated
ED060XD4 calibration only. Installing replaces the user partition and
bootloader. Keep the full verified factory dump on a second disk.
FEL after a corrupt SPL has not been demonstrated independently.

## One-time computer setup

Windows 10/11: install PowerShell 7.4+, Ubuntu WSL2 and usbipd-win
(`winget install Microsoft.PowerShell`, `winget install dorssel.usbipd-win`,
`wsl --install -d Ubuntu`). Complete Ubuntu first-run setup. In Ubuntu:
`sudo apt install python3 e2fsprogs device-tree-compiler mtools clang lld llvm usbutils libusb-1.0-0 openssl`.
Run the kit elevated if usbipd must bind the cold FEL device.

Linux: install PowerShell 7.4+ and the same Linux dependencies using
your distribution package manager. Use a local filesystem supporting
files larger than 8 GiB. Allow at least 30 GiB free, plus a second
backup drive. Linux launch runs as root to access USB and retain
filesystem ownership; its private outputs are root-owned.

Create `fel-inputs` next to PB626.ps1 and place the exact known-working
`pb626-spl.bin`, `direct-entry.bin` (52 bytes), and patched **Linux**
`sunxi-fel` executable in it. On Linux mark the FEL tool executable.
The SPL SHA-256 is 7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f.
The entry and FEL tool still require trusted local copies; do not use
arbitrary substitutes. This is the only unsolved distribution input.

## Normal use

Extract the one artifact on a local disk. On Windows run PB626.cmd
(or `pwsh -File PB626.ps1` from an elevated PowerShell). On Linux
run `bash pb626.sh`. Choose Install, Backup, Restore or Preflight.
For command-line use pass `-Action Install` etc. `-DataDir` selects
a private folder; the default is private/ inside the kit. The installer
prompts for cold FEL (fully power off, disconnect, hold Menu and
connect), discovers the ACM port, and verifies board identity and CID
with the existing recovery protocol. Never execute SPL twice in one
power cycle. `-UseRunningRecovery` is for a previously confirmed RAM
recovery only, not an ordinary boot.

Install creates or explicitly reuses a verified stock backup, extracts
the owner's waveform/VCOM, reconstructs the tested BT0 byte-for-byte,
builds the private Debian image and performs the existing read-only
preflight. It asks for the new root password and the destructive RESTORE
CID confirmation. It writes only changed 4 MiB blocks (compressed on
the wire when worthwhile), placing user block 0 last, then verifies all
three eMMC regions. The old backup and new image are retained; do not
share them. Backup now sends zero blocks as metadata only and optionally compresses
other blocks, falling back to raw for incompressible data. Every decoded
4 MiB block and all three complete images are still hashed. The raw
protocol remains available with Backup-PB626Fast.ps1 -Raw. Full backup
and readback still take time; no physical throughput measurement is claimed. No automatic retry on a failed flash.

Recovery runs entirely in RAM using Debian 13 armhf busybox-static and
a static helper, not a full desktop or APT installation. The shared
kernel and dedicated recovery DTB disable unneeded peripherals, and
all eMMC regions are locked read-only before any ACM shell is exposed.
No eMMC partition is mounted. The protocol temporarily unlocks only
the selected region for a verified payload, then relocks it. The
shell is intentionally unauthenticated physical recovery; do not
attach to an untrusted host. A successful FEL execute is not evidence
of boot: the ACM and board/CID preflight must also succeed.

Both the kit and recovery are pre-hardware-test candidates. The original
manual procedure remains in INSTALL.md. A source-reproducible SPL and
independent hardware recovery remain prerequisites for public one-click
distribution without private inputs.

## Updating without a fresh backup

Menu item 5 (or `-Action Install -SkipBackup -StockDir PATH`) creates
a new Debian image from a verified existing same-device dump without
reading another backup from the device. The original is not overwritten;
each build gets a unique linux-* output directory. The existing dump
supplies the factory partitions, calibration and identity. This is a
destructive reinstall of p1, not an in-place package upgrade. It can
restore preserved partitions to the state of that dump. No new backup
is needed if you already have one. Menu item 6 (or `-Action Flash
-ImageDir PATH`) flashes an already assembled image with no new backup.
Neither option bypasses manifest, board, CID or write confirmation.

## microSD

The default recovery DTB remains eMMC-only because MMC0 I/O previously
stalled on this board. Menu items 7–9 (or `-Action Backup -SD`,
`-Action Restore -SD`, `-Action Preflight -SD`) explicitly select
the SD-capable recovery DTB, with a 12.5 MHz limit and no 1.8 V switching.
This is the same RAM initramfs and kernel, not a second OS. It resolves
the removable SD card on physical MMC0, not eMMC, locks it read-only
and requires matching CID and exact capacity for each transfer. Card
images have pb626-sd.img, pb626-sd-cid.txt and SHA256SUMS, including any
partial final 4 MiB block. Restore checks the complete hash and only
unlocks the chosen card for writes. Never remove the card mid-operation.
An existing image can be restored to another identical-size SD only with
the explicit low-level -AllowOtherCard option and target CID confirmation.
For eMMC plus SD diagnostic access, use -EnableRecoverySD. The native
Debian MMC0 default is unchanged. If SD hangs, return to cold FEL and
use the ordinary eMMC-only profile. SD hardware stability is unqualified.

## Explicit full builds

Use the manual firmware workflow, or on enhance/native-reliability change
`.github/firmware-build-request` to request the Debian-only build. Ordinary
commits do not trigger the expensive build. The request workflow reuses the
same pinned kernel and Debian artifact jobs; Alpine-only jobs are skipped.
The resulting `pb626-debian-flash-kit` is the intended paired package.

## Full flash semantics and diagnostic ACM

Install and Flash are full raw-image operations, not a package upgrade:
user area LBA 16–63 contains BT0, LBA 80 onward contains raw kernel/DTB,
p1 contains rootfs. Both hardware boot areas and all other user-area
blocks are scanned and restored to their expected contents. Install
preserves factory-specific regions from the input dump. Restore writes
all changed blocks of a full backup. EXT_CSD is recorded and checked,
not blindly programmed; RPMB is not a raw restorable block region.
Recovery starts ConfigFS ACM automatically before storage initialization.
An invalid or unavailable eMMC no longer suppresses its diagnostic shell;
the storage protocol waits for/requires successful independent preflight.
No block device is mounted and storage writes remain CID/hash checked.
