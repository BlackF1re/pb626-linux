# pb626-linux

Development Linux for PocketBook 626 Plus / Touch Lux 3 (Allwinner A13).

**Boot path:** USB FEL → kernel and initramfs in RAM → Alpine on removable
microSD. The factory eMMC must not be modified. E Ink display, frontlight and
touchscreen are not functional yet; USB serial console and Wi-Fi were working
in previous hardware tests.

## Windows: fresh microSD and FEL boot

1. Download the `pb626-alpine-sd-image` artifact from the latest successful
   [Alpine microSD image](https://github.com/BlackF1re/pb626-linux/actions/workflows/sd-image.yml)
   workflow. Unzip the Actions artifact to obtain `pb626-alpine-sd.img.gz`.
2. With the microSD in a **PC USB card reader**, use
   [balenaEtcher](https://etcher.balena.io/) to flash the `.img.gz` onto
   **that removable microSD only**. Flashing erases the card. Do not select
   the computer disk, the reader's eMMC or another removable drive.
3. Optional Wi-Fi autoconnect: Windows should expose the card's FAT32
   partition as `PB626CFG`. Create a `wifi.conf` in that partition,
   using standard wpa_supplicant syntax:

   ```text
   ctrl_interface=/run/wpa_supplicant
   network={
       ssid="YOUR_SSID"
       psk="YOUR_PASSWORD"
   }
   ```

   Do not commit this file or store Wi-Fi passwords in CI.
4. Insert the card into the **powered-off** PocketBook. Connect USB to the
   Windows PC and hold the far-right Menu button while powering on to enter
   FEL. In **PowerShell**, check `usbipd list` for `1f3a:efe8`.
5. For the existing proven uploader in WSL `XperiaDev`, perform:

   ```powershell
   wsl -d XperiaDev -u root -- true
   usbipd attach --wsl --busid BUSID
   wsl -d XperiaDev -u root -- bash -lc '/root/pb626-lab/try-fel-direct.sh'
   ```

   Substitute the actual FEL `BUSID`. If USB binding is needed first,
   run `usbipd bind --busid BUSID` from an elevated PowerShell. WSL is
   **only** the USB FEL transport; all new images are built in Actions.
   The uploader still depends on previously working lab binaries stored in
   `/root/pb626-lab`; there is not yet a fully self-contained kernel build.
6. In PowerShell, find the Linux USB serial device:

   ```powershell
   Get-PnpDevice -PresentOnly -Class Ports |
     Where-Object InstanceId -like 'USB\VID_0525&PID_A4A7*'
   putty -serial COM7 -sercfg 115200,8,n,1,N
   ```

   Replace `COM7` with the detected COM port and press Enter. The expected
   root filesystem is `/dev/mmcblk0p1` on the **microSD**, not the eMMC.

## First USB-console session

Check `cat /etc/pb626-image-id` and `mount`. On the freshly flashed card,
if the root is read-only and you intend to configure persistent SSH, run
`mount -o remount,rw /` (this writes to the removable microSD only).
Then, from the **USB COM console**, run:

```sh
passwd
ssh-keygen -A
mkdir -p /run/sshd
/usr/sbin/sshd -o PermitRootLogin=yes -o PasswordAuthentication=yes
ip addr
```

If the Wi-Fi configuration worked, connect via `ssh root@DEVICE_IP` and
enter the password set over USB. **No default password is shipped.** A
previous experiment allowed unauthenticated root SSH; this image does not.

The image is 1 GiB: partition 1 is ext4 Alpine; partition 2 is FAT32 config.
The remainder of larger cards is left unused for now. If Linux reports MMC
I/O errors, stop rather than repeatedly forcing writes.

## Current build artifacts

- [MicroSD image workflow](.github/workflows/sd-image.yml) — working CI;
  image has **not yet been boot-tested** on the reader.
- [Device Tree workflow](.github/workflows/board.yml) — eMMC-disabled test
  DTB compiled, **not yet boot-tested**.
- [ARMv7 bootstrap workflow](.github/workflows/userland.yml) — reusable
  Alpine minirootfs, not a bootable image.

All device-tree and boot changes are experimental until tested on the physical
hardware. No stage of this process flashes the factory firmware.


## New: complete Megi Linux 5.9 FEL/microSD experiment

- **[Megi FEL + microSD bundle](.github/workflows/megi-fel.yml)** builds from
  pinned Ondrej Jirman-derived Linux 5.9 source
  [e98db7f](https://github.com/sailfish-on-dontbeevil/kernel-megi/tree/e98db7f114d7602c6b847d76e183787f0c97cf5b):
  kernel zImage, four revision-specific DTBs, **matching modules**, Alpine
  microSD image, and a standalone RAM initramfs with USB recovery console.
- Board variants: **elan** (I2C 0x15, observed later eMMC unit),
  **cypress** (original Megi TMA4 0x24 board), **focaltech**
  (experimental FT5X 0x24), **no-touch** (diagnostic).
  See [hardware/revision matrix](docs/MEGI-HARDWARE.md).
- The build **preserves our proven FEL bootstrap** and does not write eMMC.
  All four new DTBs expressly disable internal MMC2. The old lab
  kernel/DTB/image workflows remain available as rollback.
- The ELAN and FocalTech DTS bindings are *hypotheses*, not verified working
  drivers. The Megi E Ink driver exposes /dev/eink-panel but cannot display
  content without a userspace waveform update engine. Kernel boot, frontlight,
  Wi-Fi, touchscreen, power control and display remain to be tested on hardware.
- To try the new bundle: first make a backup of all files on the **removable
  microSD**, then write `pb626-megi-sd.img.gz` to that microSD only.
  Extract the Actions bundle on Windows, hold Menu to enter FEL, and run
  `scripts/Start-PB626.ps1 -BundleDir 'C:\\path\\to\\artifact' -Variant elan`.
  This stages zImage/DTB/initramfs into `/root/pb626-lab`, backs up the three
  previously proven inputs there, attaches FEL over usbipd and uses the
  existing RAM uploader. Find the new USB gadget COM port afterwards.
  **Never select the 8 GiB internal eMMC or your PC SSD as the image target.**

The main eMMC user area has been backed up separately; eMMC boot0/boot1 and
the recovery method are *not yet verified*. No eMMC installation is in scope.
