# PocketBook 626 Plus / Touch Lux 3 — Megi Linux 5.9

Development Linux for the Allwinner A13 (256 MiB), booted **into RAM using FEL**.
The current branch builds a **complete Alpine RAM root filesystem** containing
matching kernel modules, firmware and inspection tools. Future external rootfs
handoff is opt-in with `pb626.root=sd` in DTB bootargs; nothing mounts a
card by default. The factory eMMC and bootloader must remain untouched.

**Current status:** an experimental Megi 5.9 zImage and its ELAN-specific DTB,
initramfs and 52-byte entry stub were all transferred and verified in DRAM.
The CPU left FEL after `execute`, but **Linux USB serial `0525:a4a7` has not
been observed**. Full Linux boot and all E Ink functions are **not verified**.
The frontlight can appear stuck at maximum. Do not use this as an everyday
reader OS yet.

## One supported FEL loader (Windows PowerShell + WSL)

Use only these paired scripts:
- [`scripts/Start-PB626.ps1`](scripts/Start-PB626.ps1) — Windows: detect FEL,
  `usbipd bind/attach`, verify checksums, call Linux loader, list USB devices.
- [`scripts/fel-boot.sh`](scripts/fel-boot.sh) — WSL: patched FEL transport,
  **one** SPL per cold power cycle, byte-checked 64 KiB DRAM transfers,
  `execute` and postboot USB inspection. Both scripts have explanatory comments.

Prerequisites: `usbipd` on Windows; WSL2 distribution `XperiaDev` with
`usbutils`; the locally validated patched sunxi-fel at
`/root/pb626-lab/retry-tools/sunxi-tools-master/sunxi-fel` and two local
boot files `pb626-spl.bin` and `direct-entry.bin` at `/root/pb626-lab`.
These local binaries have **not yet been brought under reproducible CI**.

1. Download the latest `pb626-megi-fel-sd-bundle` artifact from a successful
   [Megi workflow](.github/workflows/megi-fel.yml) and extract it to
   `C:\PB626\bundle`. Use a new successful RAM Linux build containing the fixed `/memory` node,
   `/chosen/linux,initrd-start/end` and matching RAM modules.
2. Save **both** loader scripts in `C:\PB626` (side by side).
3. Power off the reader completely, enter FEL using the far-right Menu
   button, then execute in PowerShell:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass `
     -File C:\PB626\Start-PB626.ps1 `
     -BundleDir C:\PB626\bundle `
     -Variant elan -Profile standard
   ```

The default **standard** image is now a complete RAM Linux environment.
`-Profile diagnostic` is a backwards-compatible alias for the same image,
not a separate downloadable ZIP. Download the successful **RAM Linux**
workflow artifact; do not use the older `pb626-megi-fel-sd-bundle.zip`.

A future removable rootfs is built as `pb626-megi-rootfs.tar.gz`, but no SD
disk image is produced in this phase. Use `pb626.root=sd` in DTB `/chosen/bootargs`
only when deliberately testing removable rootfs. MMC2/eMMC stays disabled.

The WSL FEL uploader now requires `fdtget` (package `device-tree-compiler`)
for pre-execute RAM, initrd and MMC2 checks.

**To connect:** only after Linux gadget `0525:a4a7` is actually present, open
its COM port in PuTTY at 115200 8N1 (press Enter), or attach the gadget to WSL
and use `/dev/ttyACM*`. Today this device **has not enumerated**, so no
interactive shell is yet available.

See [`docs/MEGI-BOOT-AND-HARDWARE.md`](docs/MEGI-BOOT-AND-HARDWARE.md)
for the pinned Megi source revision, provenance, limitations and the full
boot boundary. Full upstream driver source is fetched from the **pinned
Megi repository**; it is not copied wholesale into this repo.
## Development readiness

The WIP pull request is **not** a confirmed bootable release. Current
SPL, 52-byte entry stub and patched FEL tool still exist outside source
control in the developer's WSL lab. Do not interpret passing CI as proof
of working E Ink, ELAN touch, frontlight or system boot. Refer to
[RAM Linux design](docs/RAM-LINUX-DESIGN.md) for risks and milestones.
