# PocketBook 626 Plus / Touch Lux 3 — Alpine Linux 3.24 / Megi 7.2

**Hardware milestone: 2026-11-21 — interactive Alpine Linux shell reached on one
PocketBook 626 Plus / Touch Lux 3 (Allwinner A13, ELAN revision) using RAM-only
USB FEL boot.** This is an experimental Linux bring-up. RAM variants leave
the factory eMMC untouched.

## Experimental installation to internal eMMC

For the verified ELAN board with the factory Samsung 8WPD3R layout, save a
full eMMC backup first. Boot the GitHub Actions bundle into RAM with
`scripts/Start-PB626.ps1 -BundleDir <bundle> -Variant elan-emmc-install -Profile diagnostic`.
In the USB serial shell, run `install-pb626-emmc` to see the target CID.
Run it again with that CID to replace p8 with Alpine and configure the factory
loader on p2. After it reports completion, run `sync; reboot -f` without
holding the FEL button. Installation and read-back of the files have been
verified. Cold boot into the installed Alpine system is still unresolved.
The panel waveform is at `/lib/firmware/pb626/default.wbf`.

The BootROM reads `eGON.BT0` at byte offset `0x2000` in the eMMC user area.
BT0 reads and checksums `eGON.BT1` from LBA 38192 (`0x012a6000`) and runs
it at `0x42400000`. The dump also contains an identical copy at
`0x012e6000`. BT1 loads `/boot.axf` from the FAT16 bootloader partition
(p2, LBA 73728). The AXF reads `/linux/linux.ini` for normal boot or
`/linux/recovery.ini` for recovery. The normal configuration loads up
to 8 MiB of raw ARM code from `/linux/bImage` at `0x40008000`. BT1
disables the MMU and caches before calling that address with ATAGs at
`0x40000100`. The factory kernel uses p7 as its root.

The installer keeps the 8 MiB single-segment layout. The ARM zImage
reads its appended board DTB and mounts Alpine from p8 directly.
The stock application also lives on p8, so
restoring only the stock kernel can cause the factory OS to start
its automatic updater.

To restore the factory system, use the full backup or restore the original
p8 and the boot files in p2's `linux/` directory from FEL. Rename
`bImage.pb` to `bImage` and restore each `*.ini.factory` as its matching
`*.ini` file.

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
- The `elan-display` variant boots with the frontlight off. Two brightness
  levels and switch-off were verified through `/sys/class/backlight`.
- The ED060XD4 panel cleared to white, displayed monochrome and 16-level
  grayscale patterns, and updated a region through the `sun5i-eink` V4L2
  output at `/dev/video0`. Tests used factory waveforms and calibrated VCOM.
- USB with factory-compatible PG1 VBUS sensing did **not** enumerate. The
  `elan-usbtest` variant, which removes that sensing GPIO and uses the
  sun4i PHY fallback, **did enumerate**. This diagnoses a likely modern-driver
  VBUS-detection problem but is not proof PG1 is miswired. The factory OS
  successfully uses the same PG1 GPIO.

**Not yet verified:** touch input, battery/power management, suspend, Wi-Fi,
removable SD root, panel
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
4. For the **specific already-verified ELAN reader**, use the display
   diagnostic variant:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass `
     -File C:\PB626\Start-PB626.ps1 `
     -BundleDir C:\PB626\bundle `
     -Variant elan-display -Profile diagnostic -Distro XperiaDev
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

Copy the panel's factory `default.wbf` from the offline dump into `/run`.
On the reader, run `pb626-epd /run/default.wbf full /run/page.pgm` for
GC16 or use `partial` for GL16 over changed pixels. Supply a binary PGM
(P5) at 758 × 1024 in portrait orientation. The utility reads the TPS65185
temperature and resets an unknown screen state to white before updating.
It also accepts `reset`, `du`, `a2`, and `du4`. The three fast modes
require transitions supported by their factory tables. If another program
uses the raw V4L2 output, run `reset` before resuming with `pb626-epd`.

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

## Test Wi-Fi / monitor capabilities (experimental)

The current RAM-only demo includes an **explicitly user-authorized public,
disposable test network**, SSID `ACCESS_POINT` and passphrase `PASSWORD`.
The `/init` script sets hostname `pb626` and runs `pb626-network`
non-blockingly. This supplies WPA/WPA2-PSK; **if the AP is WPA3-only or
enterprise/802.1X, it will not associate**. Network/firmware availability is
reported in `/run/pb626-network.log` and verified with `iw dev wlan0 link`,
`ip address show wlan0`, and `ip route`. The Wi-Fi configuration is in
RAM and never persisted to eMMC. Do not put real credentials into the public
`board/megi/wifi-test.conf` file.

Physical RTL8188EU `0bda:8179` was enumerated on the PocketBook, and the
`rtl8xxxu` driver loaded firmware revision 28.0 from decompressed
`rtl8188eufw.bin`; `iw list` reported `managed` and `monitor` and
created `wlan0`. **SSID association/DHCP, actual monitor reception, and
transmit injection are not yet proven**. The image includes `tcpdump` for
controlled passive receive tests. Do not confuse advertised monitor support
with verified packet injection.

`lm-sensors` was confirmed to print AXP209 USB and battery voltage/current;
`power_supply` separately exports battery charge state/capacity. OpenSSH
is installed but no TCP listener was present; no unrestricted root SSH
service is enabled. Avoid starting unauthenticated root SSH on Wi-Fi.

## hcxdumptool lab-only diagnostics

The ARMv7 Alpine RAM image also contains **hcxdumptool 7.1.2**, built from
ZerBea upstream Git revision `10aa88d3e955f507f56d24d3779ac251c4004c1c`
under QEMU; no compiler, build dependencies, or tools are installed to factory
flash. The bundled tool is not launched automatically. Its default operation
includes active Wi-Fi interaction, possibly disconnecting stations and
recording authentication-related data. Use only in a radio-shielded, fully
owned lab. The project intentionally retains the USB CDC console as the
control channel while hcxdumptool takes exclusive control of the real
`wlan0`; do **not** run it on `mon0` or concurrently with
`wpa_supplicant`/Aircrack-ng. A user must start/stop it explicitly.

A prior live experiment confirmed RTL8188EU monitor reception (20 Beacon frames,
Radiotap with RSSI/channel/TSFT) and an Aircrack-ng directed probe test against
user-owned AP `ACCESS_POINT` returned **30/30 responses (100%)** on channel 11.
Those results demonstrate basic injection but do not guarantee the distinct
802.11 operations used by hcxdumptool will succeed with `rtl8xxxu`.

## Experimental RTL8188EU monitor-only RX regression test (2026-11-21)

On the physical reader, RTL8188EU + `rtl8xxxu` under Megi 7.2 successfully
captured Beacon frames with a separately created `mon0`, and probe injection
returned 30/30 replies. But converting the existing `wlan0` from managed
to monitor yielded **zero received frames**, including with `tcpdump` and
`hcxdumptool`. Reapplying `iw ... set monitor control otherbss` did not
resolve the failure. Re-association in managed mode and reloading the module
both restored reception.

A **test-only, unverified** kernel patch
`patches/rtl8xxxu-reset-linktype.patch` clears the hardware link type to
`MSR_LINKTYPE_NONE` in `rtl8xxxu_remove_interface()` after removal of a
managed VIF. It addresses the observation that `rtl8xxxu_add_interface()`
sets station link type, but removal previously cleared only the software VIF
pointer. This is a hypothesis, **not an established root cause**. Never
assume the patch works until the on-device negative/positive test is repeated.

This patch changes only the external RAM boot kernel and is pinned and built
in CI. Original DTB eMMC-disabled and frontlight safety checks remain in place.
