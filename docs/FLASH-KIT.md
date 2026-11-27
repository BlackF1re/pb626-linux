# USB Ethernet recovery (new paired kit)

Normal Install, Backup, Restore and Preflight use a dedicated CDC NCM USB Ethernet link (169.254.62.1/30 device, .2 host; TCP 6262). ACM stays available for diagnostic/emergency shell access. Windows attaches the composite gadget to WSL via usbipd; use a WSL kernel with cdc_ncm and install iproute2, Python 3.7+ and openssl in WSL. Native Linux uses the same transport. No Windows Python/pyserial needed for normal installation. Existing ACM dump tools remain emergency tools only; never use them concurrently with the TCP service. The NCM driver and USB composite enumeration require physical qualification. If the composite UDC cannot bind, recovery falls back to ACM-only diagnostics; normal bulk actions then fail closed rather than silently using slow ACM. The recovery service binds only usb0 and accepts only the dedicated peer; it is not a general remote shell. Do not bridge this interface to other networks.

Direct Install requires the new paired kernel and recovery. The new kit includes a CI-generated ext4 allocation map; only chunks consisting entirely of filesystem-free zero blocks are omitted. This is not a secure erase of old free space. Mapped blocks are hash-verified and read back; full dumps are still byte-for-byte, with existing manifest filenames. A 4 MiB random TCP integrity test and verification of personalization input happen before the first write. Rootfs is written first, then personalized, then raw kernel/DTB, then exact BT0 last. No full backup is read or created by Install. A failed write is never automatically retried. Keep the book in recovery if it fails.

`PB626.ps1 -Action Install -Distro XperiaDev` runs on Windows PowerShell 5.1 and PowerShell 7. The Windows installer and FEL launcher do not require PowerShell 7; Linux-native use of `pb626.sh` still requires PowerShell 7.4+. Do not use the old running recovery with the new kit; cold boot its paired RAM recovery first. The old ACM scripts in tools are reserved for emergencies. New network dump commands require exact CID and EXT_CSD layout; the legacy AllowOtherCard option is not provided by the normal launcher.

# PB626 Debian flash kit (candidate)

One artifact, `pb626-debian-flash-kit`, contains the same-run flashable native
Debian system, minimal RAM recovery, host backup/restore tools, offline
assembler and entry points. It does not contain any private factory
data, password, or the unrecovered private SPL inputs.

Supported hardware: late ELAN/eKTF2227, 8WPD3R eMMC and the validated
ED060XD4 calibration only. Installing replaces the user partition and
bootloader. Keep the full verified factory dump on a second disk.
FEL after a corrupt SPL has not been demonstrated independently.

## One-time computer setup

Windows 10/11: use the built-in Windows PowerShell 5.1, install Ubuntu WSL2 and usbipd-win
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
(or `powershell.exe -NoProfile -ExecutionPolicy Bypass -File PB626.ps1`
from an elevated Windows PowerShell 5.1). On Linux run `bash pb626.sh`.
Choose Install, Backup, Restore or Preflight. Use `-Action Validate` first
to verify every packaged file without accessing the reader.
For command-line use pass `-Action Install` etc. `-DataDir` selects
a private folder; the default is private/ inside the kit. The installer
prompts for cold FEL (fully power off, disconnect, hold Menu and
connect), discovers the USB composite gadget, attaches it to Linux and
verifies board identity and CID over TCP. Never execute SPL twice in one
power cycle. `-UseRunningRecovery` is for a previously confirmed RAM
recovery only, not an ordinary boot.

Install now streams the Actions-built `native/pb626-rootfs.ext4.gz` directly into p1, personalizes it with the owner's waveform, VCOM, sleep artwork and a new root password, writes the paired raw kernel/DTB, then reconstructs and writes the tested BT0 last. Only those three ranges are touched. No full backup, backup manifest or local ext4 creation is required. Every written block is verified. The public CI-built `pb626-bt0-menu.raw` is applied to the exact hash-qualified local SPL; no local ARM compiler is used. The private base SPL is not redistributed. No automatic retry on a failed flash.

Python 3.7+, iproute2 and OpenSSL in WSL/Linux are required. The launcher starts RAM recovery, attaches its composite USB gadget to WSL, and invokes the TCP installer. After the owner-specific files are read (not a full dump), type the displayed `FLASH CID` to write. A root password of at least four characters is accepted for local testing; use a strong unique password for real use. `-UseRunningRecovery` may be used with the paired RAM recovery already running.

Backup and Restore remain independent complete eMMC/SD dump operations. The legacy offline image builder remains available as InstallFromDump.

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

Normal `-Action Install` no longer needs a dump. Menu item 5 (or `-Action InstallFromDump -SkipBackup -StockDir PATH`) retains the legacy offline assembly from a verified existing full dump. The historical `-Action Install -SkipBackup -StockDir PATH` syntax is accepted as an alias for that legacy path. Menu item 6 (or `-Action Flash -ImageDir PATH`) is a legacy alias for restoring an already assembled full dump; `-Action Restore -ImageDir PATH` is preferred. Neither legacy option bypasses manifest, board, CID or write confirmation.

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

Install is a selective raw-image installation, not a package upgrade: user area LBA 16–63 contains BT0, LBA 80 onward contains raw kernel/DTB, p1 contains rootfs. It does not modify the MBR/EBR, BT1, other factory partitions or hardware boot areas. Restore (including the legacy Flash alias) writes all changed blocks of a full dump, including user, boot0 and boot1. EXT_CSD is recorded and checked, not blindly programmed; RPMB is not a raw restorable block region.
Recovery starts ConfigFS ACM automatically before storage initialization.
An invalid or unavailable eMMC no longer suppresses its diagnostic shell;
the storage protocol waits for/requires successful independent preflight.
No block device is mounted and storage writes remain CID/hash checked.

## Build graph and published artifacts

The explicit Debian request workflow builds the kernel, Debian base and
source SPL candidates independently. Native assembly waits for the
kernel and Debian base; minimal recovery waits only for the kernel.
Diagnostics build independently. The flash kit combines current-run
native, recovery and diagnostics, verifying commit IDs and SHA256
manifests. It deliberately does not substitute an experimental SPL
for the hash-qualified local BT0.

- pb626-kernel-stage: zImage, modules, Kconfig, DTBs, UAPI and manifest.
- pb626-native-debian13-armhf: rootfs archive, ready-to-stream exact-size compressed ext4, tested public BT0 patch, paired native raw kernel images,
  pb626-runtime_armhf.deb and package list. No redundant rootfs-only or
  runtime-only uploads.
- pb626-debian-recovery: Debian BusyBox initramfs, paired recovery DTBs,
  host restore tools and installer skeleton.
- pb626-source-boot-candidates-NOT-FOR-FLASH: source-built FEL SPL,
  native SPL, entry stub, sunxi-fel and separate deep-resume candidate.
- pb626-diagnostics: standalone POSIX shell tool with documentation.
- pb626-debian-flash-kit: complete paired distribution, still requiring
  the verified private FEL inputs until qualification.
- pb626-debian-base-stage: one-day internal chroot transport, not firmware.

Kernel/DTB caches retain pinned sources, Kconfig and toolchain keys.
The Debian signed package base and development chroot are cached
independently of the kernel and project source, with a weekly freshness
epoch. The compiled native C/Matchbox/DDX binaries are cached by base
manifest, UAPI, relevant source and build recipe. Source bootloader
caches are keyed by source inputs and toolchain fingerprint. Final
packages and kit are rebuilt from the current checkout. Main's historical
Alpine jobs remain available; explicit Debian-only builds skip them.

### Cache reuse and build provenance

Complete verified kernel/DTB/UAPI content has an exact-input cache.
On an exact hit no Linux source checkout is required. On a miss the
separate kernel and DTB caches can still be reused. The expensive
kernel recipe is a separate script; changes to unrelated workflow YAML
do not change that cache. The native compiler recipe is similarly
separate from rootfs packaging. A complete native image cache is keyed
by kernel content (not the checkout stamp), Debian base manifest and
actual native inputs. A hit skips the chroot/compiler/rootfs assembly.
CONTENT-BUILD-COMMIT identifies the checkout that actually built the
native content; BUILD-COMMIT identifies the current verified assembly.
The final manifest is regenerated on reuse. Recovery reuses signed
BusyBox and the ARM restore scanner independently. SPL keys include
only actual source and patches, not its documentation or kernel packer.
The diagnostic artifact includes the shell and native ARM timing helper.
No cache hit substitutes for a first successful build or a hardware test.

## Recovered FEL inputs

The lab archive contains the original 52-byte direct-entry assembly and
full patched sunxi-tools sources. The kit now includes a separately built
`fel-host/` directory with the byte-identical entry, host executable,
corresponding source archive and manifest. Existing known-working local
inputs remain preferred. The rebuilt host binary is not yet physically
USB-qualified; its two modified C sources are checked against the original
laboratory hashes. Install libfdt1 and zlib1g in addition to libusb in WSL.

Explicitly opt in to preparing missing inputs with menu item 11 or
`PB626.ps1 -Action Prepare` (no device access). You can pass
`-OriginalUboot PATH` to use the original combined file offline. It downloads the historical upstream
U-Boot from xff.cz directly, only accepts SHA256
ad00580889a797836b05ed8c718c11d5ccb014aa266707c4f41fa89d192fb87f,
and extracts its first 24576 bytes with the existing SPL hash check.
Existing files are not overwritten. If the upstream download is missing
or different, use the original lab uboot.bin locally with
`python3 source/scripts/prepare-fel-inputs.py --host fel-host --output
fel-inputs --uboot /path/to/uboot.bin`. The historical executable is not
republished by the kit. Verify cold FEL RAM recovery before writing eMMC.

## Unified full-build qualification

The main firmware workflow builds Alpine RAM/native, Debian native and RAM
recovery, source SPL candidates, recovered host FEL tools, diagnostics and
backup/restore tools in one run. The explicit feature-branch request
(`.github/firmware-build-request`) now invokes the same full graph before
merge, not Debian-only. Individual FEL and SPL workflows are callable or
manual-only. Lightweight PR checks remain independently available.
The flash kit requires successful host, restore, reference SPL differential
and recovered FEL checks; the final `All selected builds and tests passed`
job additionally requires both Alpine variants when selected. Its
`pb626-full-build-report` records the exact commit and every job result.

Existing kernel, DTB, distribution, native binaries, rootfs and recovery
payload caches are retained. Recovered FEL tools now have a separate
verified compiler/source-keyed cache, without private SPL inputs. The
historical author's SPL download is hash-checked each run, never published
as part of CI. GitHub cache scopes and eviction still apply; a cache miss
rebuilds from pinned sources. All downloadable firmware is still a
hardware-unqualified candidate, with the qualified historical BT0 gate intact.
