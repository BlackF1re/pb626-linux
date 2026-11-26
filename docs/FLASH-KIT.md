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
