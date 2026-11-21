# PocketBook 626 Plus / Touch Lux 3 — Alpine Linux 3.24 / Megi 7.2

**Hardware milestone: 2026-11-21 — interactive Alpine Linux shell reached on one
PocketBook 626 Plus / Touch Lux 3 (Allwinner A13, ELAN revision) using RAM-only
USB FEL boot.** This is an experimental Linux bring-up, **not a firmware update
and not yet an everyday e-reader OS**. Internal factory eMMC must remain
untouched.

## Verified on the physical reader

- FEL SPL initialized DDR, then the host transferred and read back the 7.2
  zImage, DTB, full Alpine initramfs and ARM entry stub.
- Linux reached `/init`, created a USB ConfigFS ACM gadget, registered
  `musb-hdrc.1.auto`, and enumerated on the Windows host as **0525:a4a7**,
  serial `PB626RAM01`, on COM12 in this experiment.
- An interactive shell responded over the COM port:
  - `uname -a`: `Linux (none) 7.2.0-gfacc87117511 ... armv7l Linux`.
  - `/etc/os-release`: `Alpine Linux v3.24.4`.
  - `cat /sys/class/udc/*/state`: `configured`.
- Frontlight control requires further driver work. On this unit the
  `elan-lightoff` and `elan-usbtest` DTBs disable the PWM/backlight drivers
  and hold active-high enable PB4 LOW: this **physically extinguished** the
  frontlight in a real boot. The stock `elan` DTB left it brightly lit.
- USB with factory-compatible PG1 VBUS sensing did **not** enumerate. The
  `elan-usbtest` variant, which removes that sensing GPIO and uses the
  sun4i PHY fallback, **did enumerate**. This diagnoses a likely modern-driver
  VBUS-detection problem but is not proof PG1 is miswired. The factory OS
  successfully uses the same PG1 GPIO.

**Not yet verified:** E Ink display refresh and waveform driving, touch
input, battery/power management, suspend, Wi-Fi, removable SD root, panel
voltage safety on other units, or boot without the local FEL tools.

## RAM-only safety boundary

The default boot image is a full Alpine ARMv7 initramfs with matching kernel
modules. The device tree has the internal eMMC controller
`/soc/mmc@1c11000` set to `status = "disabled"`; the FEL uploader checks
this before execution. No flash/erase/eMMC write commands are part of the
loader. Optional SD root handoff requires `pb626.root=sd`, is read-only, and
is *not* enabled by default.

The local SPL, custom 52-byte ARM entry stub, and patched `sunxi-fel` are
still outside this repository at `/root/pb626-lab` in WSL. CI cannot yet
reproduce that part of the boot chain. **Do not run SPL twice in the same
power cycle**; fully power off the reader before starting FEL again.

The `elan` DTBs include panel VCOM calibrated from the factory files of
**one unit** (−2440 mV). Do not use them on an unverified unit without first
checking its own calibration.

## Reproduce the verified RAM session

Requirements: Windows PowerShell 5.1, `usbipd`, WSL2 distribution
`XperiaDev`, `usbutils` and `device-tree-compiler` in WSL, and the known
local FEL tools/SPL/stub.

1. Download `pb626-mainline-7.2-ram-bundle` from a **successful**
   [Megi Linux 7.2 GitHub Actions workflow](.github/workflows/megi-fel.yml).
   Extract all files to `C:\PB626\bundle`; do not mix builds.
2. Save current `scripts/Start-PB626.ps1` and `scripts/fel-boot.sh` beside
   one another at `C:\PB626`.
3. Fully power off, disconnect USB, then enter FEL using the far-right
   **Menu** button while reconnecting the USB cable.
4. For the **specific already-verified ELAN reader**, use the experimental
   USB/frontlight diagnostic variant:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass `
     -File C:\PB626\Start-PB626.ps1 `
     -BundleDir C:\PB626\bundle `
     -Variant elan-usbtest -Profile standard -Distro XperiaDev
   ```

   `elan-lightoff` leaves factory PG1 USB sensing in place, turning off
   the frontlight but **not** enumerating USB on the observed reader. The
   standard `elan` variant has not achieved safe frontlight behavior. These
   experimental DTBs must not be treated as production device definitions.

5. When Windows discovers VID:PID `0525:a4a7`, find its **current** COM
   number (COM12 was observed, but may change). Connect in PuTTY at
   **115200 8N1 with no flow control**, press Enter, and run:

   ```sh
   uname -a
   cat /etc/os-release
   cat /sys/class/udc/*/state
   cat /run/pb626-boot.log
   ```

If the frontlight stays at maximum unexpectedly, promptly power down; do
not leave an unverified image running. Do not assume an `execute` return code
proves Linux booted: verify the console and kernel output.

## Development / build

GitHub Actions builds the pinned Megi mainline-based kernel and Alpine rootfs
as separate cached jobs, then assembles a RAM-only bundle with six DTB
variants. Source: Megi's `orange-pi-7.2-20260903-2131`, Git commit
`facc87117511221bb61410e3f92ad8579697f736` (mirror:
https://github.com/Arnavion/linux/tree/orange-pi-7.2-20260903-2131).
The tree is **mainline-based plus downstream PocketBook E Ink support**, not
unmodified upstream Linux.

Further architecture and safety notes:
[Full RAM Linux design](docs/RAM-LINUX-DESIGN.md) and
[Megi boot / hardware](docs/MEGI-BOOT-AND-HARDWARE.md).
