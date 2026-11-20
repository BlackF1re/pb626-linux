# PocketBook 626 Plus / Touch Lux 3 — Megi Linux 5.9

Development Linux for the Allwinner A13 (256 MiB), booted **into RAM using FEL**.
The factory eMMC and bootloader must remain untouched.

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

1. Download `pb626-megi-fel-sd-bundle.zip` from the successful
   [Megi workflow](.github/workflows/megi-fel.yml) and extract it to
   `C:\PB626\bundle`. Use a build containing the fixed `/memory` node and
   `/chosen/linux,initrd-start/end`, not the older 2026-11-20 artifacts.
2. Save **both** loader scripts in `C:\PB626` (side by side).
3. Power off the reader completely, enter FEL using the far-right Menu
   button, then execute in PowerShell:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass `
     -File C:\PB626\Start-PB626.ps1 `
     -BundleDir C:\PB626\bundle `
     -Variant elan -Profile standard
   ```

For the **RAM-only diagnostic** archive (no microSD access), extract it to
`C:\PB626\memfix` and substitute `-BundleDir C:\PB626\memfix -Profile diagnostic`.
A standard Megi initramfs attempts removable microSD root read-only; it does
**not** install onto the internal eMMC. If an SD image is flashed, do it only
onto a physically removable microSD in a PC card reader.

**To connect:** only after Linux gadget `0525:a4a7` is actually present, open
its COM port in PuTTY at 115200 8N1 (press Enter), or attach the gadget to WSL
and use `/dev/ttyACM*`. Today this device **has not enumerated**, so no
interactive shell is yet available.

See [`docs/MEGI-BOOT-AND-HARDWARE.md`](docs/MEGI-BOOT-AND-HARDWARE.md)
for the pinned Megi source revision, provenance, limitations and the full
boot boundary. Full upstream driver source is fetched from the **pinned
Megi repository**; it is not copied wholesale into this repo.