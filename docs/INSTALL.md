# Install, back up and restore PocketBook 626 Linux

> **Historical installation guide. For the current paired Debian installer, use [Windows flashing](WINDOWS-FLASH.md). The former standalone Linux/WSL and Alpine firmware bundles are not built by the active workflow.**

For normal Debian installation, use the paired Actions artifact `pb626-debian-flash-kit` and `PB626.ps1 -Action Install`. It streams a CI-built ext4 image, kernel and tested BT0 without reading a full dump or building a filesystem locally; see [FLASH-KIT.md](FLASH-KIT.md). The steps below are the legacy offline full-dump procedure and recovery fallback.

This guide uses Windows 10/11 and Ubuntu in WSL2. You do not need to compile Linux or the desktop.

> [!CAUTION]
> Only the late **ELAN eKTF2227 / Samsung 8WPD3R eMMC** board with the verified ED060XD4 panel calibration is supported. The model name alone is not enough. If you already have a stock SSH console, the read-only [hardware inventory](../scripts/probe-device.sh) reports touch input and the eMMC model without collecting its CID. Installation deletes all books and files on the original user partition and replaces the primary bootloader. The offline installer and new backup path have not yet been tested on a physical reader. If you are unsure about your hardware, stop and ask in [Issues](https://github.com/BlackF1re/pb626-linux/issues).

> [!IMPORTANT]
> **Before starting:** you must already have the verified FEL files listed in step 1. The exact lab SPL and 52-byte entry stub are not available as a public, reproducible download. There is no supported way to complete this guide without them. Do not download a random SPL, use another panel's waveform, or bypass an error.

## 1. Prepare your computer

Use a charged reader, a reliable USB data cable and a Windows PC with at least 30 GiB free for the factory dump, new image and temporary files. Do not put the backup on a FAT32 drive.

Open **Start → Windows PowerShell → Run as administrator**. Paste these commands one at a time (skip software you already have):

```powershell
wsl --install -d Ubuntu
winget install --id Microsoft.PowerShell --exact
winget install --id dorssel.usbipd-win --exact
```

Restart Windows if requested. Open **Ubuntu** from Start and complete its first-run username/password setup. In Ubuntu, install the required tools:

```bash
sudo apt update
sudo apt install -y python3 e2fsprogs device-tree-compiler mtools clang lld llvm usbutils libusb-1.0-0 openssl
```

If you use an existing WSL distribution instead, run wsl -l -v in Windows to find its name and substitute it for Ubuntu in later commands. It must be WSL version 2.

In Windows Explorer create C:\PB626 and C:\PB626\fel-inputs. Put these three **verified local files** in fel-inputs:

- pb626-spl.bin — exact lab SPL ([required SHA-256](../BT0-uncaged/README.md)).
- direct-entry.bin — known-working 52-byte entry stub.
- sunxi-fel — Linux executable built with [the FEL MMU patch](../patches/sunxi-fel-keep-mmu-off.patch).

In Ubuntu, copy them into the directory expected by the launcher:

```bash
sudo install -Dm644 /mnt/c/PB626/fel-inputs/pb626-spl.bin /root/pb626-lab/pb626-spl.bin
sudo install -Dm644 /mnt/c/PB626/fel-inputs/direct-entry.bin /root/pb626-lab/direct-entry.bin
sudo install -Dm755 /mnt/c/PB626/fel-inputs/sunxi-fel /root/pb626-lab/retry-tools/sunxi-tools-master/sunxi-fel
```

Verify the base SPL and entry size:

```bash
sudo sha256sum /root/pb626-lab/pb626-spl.bin
sudo stat -c '%s' /root/pb626-lab/direct-entry.bin
```

The first result must be 7543ab1379d19cd07cd01e7ea3ff7d257aada22f770d0e937a6ae0605732a38f; the second must be 52. The stub's size alone does not establish authenticity; use only the known-working copy.

## 2. Download and unpack the files

Sign in to GitHub. Open [firmware Actions](https://github.com/BlackF1re/pb626-linux/actions/workflows/megi-fel.yml), select a **successful** run on the main branch, scroll to **Artifacts** and download both ZIPs from the same run:

- pb626-mainline-7.2-ram-bundle → extract to C:\PB626\FEL
- pb626-native-system → extract to C:\PB626\native

Open [recovery Actions](https://github.com/BlackF1re/pb626-linux/actions/workflows/restore.yml), select the successful recovery build for the same source (or unchanged recovery code), and download pb626-emmc-tools → extract to C:\PB626\tools.

For the installer source, use the exact commit printed in the native artifact's BUILD-COMMIT file. Open https://github.com/BlackF1re/pb626-linux/tree/ followed by that commit in your browser, then use **Code → Download ZIP**. Extract the contents to C:\PB626\source (the directory must directly contain scripts and BT0-uncaged).

Use Explorer's **Extract All**, not the ZIP preview. Check that these paths exist (there must not be an extra nested ZIP directory):

```text
C:\PB626\FEL\Start-PB626.ps1
C:\PB626\FEL\SHA256SUMS
C:\PB626\native\SHA256SUMS
C:\PB626\tools\Backup-PB626Fast.ps1
C:\PB626\tools\Restore-PB626Fast.ps1
C:\PB626\source\scripts\build-native-image.py
```

In Ubuntu, verify the downloaded archives' contents:

```bash
(cd /mnt/c/PB626/FEL && sha256sum -c SHA256SUMS)
(cd /mnt/c/PB626/native && sha256sum -c SHA256SUMS)
(cd /mnt/c/PB626/tools && if [ -f SHA256SUMS ]; then sha256sum -c SHA256SUMS; else sha256sum -c SHA256SUMS.fast; fi)
```

Every listed check must say OK. If the artifacts expired, obtain a fresh successful build instead of mixing versions. Older recovery artifacts only have SHA256SUMS.fast, which verifies the ARM helper. Download scripts only from the trusted project artifact.

## 3. Start the recovery system (no changes to the reader)

1. Turn the reader completely off and disconnect USB.
2. Hold its far-right **Menu** button and plug USB into the PC. This is Allwinner FEL mode (the SoC's built-in USB recovery mode, not normal USB storage); usbipd list should show 1f3a:efe8.
3. Open **Windows PowerShell as administrator** and paste:

```powershell
cd C:\PB626
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\FEL\Start-PB626.ps1 -BundleDir .\FEL -Distro Ubuntu -Variant elan-emmc-backup -Profile diagnostic
```

The recovery system runs entirely in RAM. It leaves the eMMC read-only, unmounted and the frontlight off.

4. When the command finishes, find the Linux USB serial port in its output. You can also open **Device Manager → Ports (COM & LPT)**. It must correspond to USB VID:PID 0525:a4a7, not the original FEL device.

```powershell
Get-PnpDevice -PresentOnly | Where-Object InstanceId -match 'VID_0525&PID_A4A7' | Format-Table Status,FriendlyName,InstanceId
```

Write down the COM number (e.g. COM12). If no port appears, Linux has not been confirmed to boot. If the light remains bright, power off. Never execute the SPL twice in one power cycle: turn the reader off, unplug, and start this step again. Do not proceed until the Linux COM port appears.

## 4. Save a factory backup

Do this while the reader still contains the original factory firmware.

In Windows PowerShell, launch **PowerShell 7** with a process-only execution policy:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass
```

Paste these commands in the new shell. Replace COM12 with the number from step 3:

```powershell
cd C:\PB626
$Port = 'COM12'
.\tools\Backup-PB626Fast.ps1 -Port $Port -BackupDir C:\PB626\stock
```

Close PuTTY or any other serial terminal before running the backup. The destination stock directory must not already exist. Do not disconnect USB during the transfer.

Wait for **All three eMMC regions backed up and verified.** You should now have these six files:

```text
pb626-emmc-user.img
pb626-emmc-boot0.img
pb626-emmc-boot1.img
pb626-emmc-ext-csd.bin
pb626-emmc-cid.txt
SHA256SUMS
```

In Ubuntu:

```bash
(cd /mnt/c/PB626/stock && sha256sum -c SHA256SUMS)
```

Every check must say OK. Copy the entire stock folder to a second drive and keep it private. An incomplete folder or a dump made after installing Linux is not a factory backup. A verified backup includes your books, device-specific state and original bootloaders.

For an already modified reader, make a separate backup with a new folder such as C:\PB626\working, never overwrite stock.

## 5. Prepare the Linux image on the PC

This step only creates files on your computer; it does not write to the reader.

In Ubuntu, extract the original screen waveform from the factory dump's FAT16 boot partition and check its calibration:

```bash
mcopy -i /mnt/c/PB626/stock/pb626-emmc-user.img@@37748736 ::/default.wbf /mnt/c/PB626/default.wbf
mtype -i /mnt/c/PB626/stock/pb626-emmc-user.img@@37748736 ::/vcom
sha256sum /mnt/c/PB626/default.wbf
```

The factory VCOM must be −2440 mV and the waveform hash must be:

```text
bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f
```

If these files are absent from your dump or either value differs, **stop**. Do not borrow a waveform or change the voltage to make it pass.

Still in Ubuntu, reconstruct the verified primary bootloader and assemble the new image:

```bash
cd /mnt/c/PB626/source
sudo python3 BT0-uncaged/build.py /root/pb626-lab/pb626-spl.bin /mnt/c/PB626/BT0-uncaged.bin
python3 BT0-uncaged/test_hook.py /mnt/c/PB626/BT0-uncaged.bin
```

If a test or checksum fails, stop.

```bash
sudo python3 scripts/build-native-image.py \
  --backup /mnt/c/PB626/stock \
  --system /mnt/c/PB626/native \
  --spl /mnt/c/PB626/BT0-uncaged.bin \
  --waveform /mnt/c/PB626/default.wbf \
  --output /mnt/c/PB626/linux \
  --accept-replace-p1
```

The builder prompts for a new root password (not included in CI artifacts). Keep it private. For unattended assembly, pass `--root-password-hash-file` with a private SHA-512 crypt hash generated by `openssl passwd -6`. The output is a private image containing the password hash.

For Debian, the assembler reads the original Line.pbt from preserved stock p8 using read-only debugfs (e2fsprogs) and verifies the theme and two bitmaps before installing them into the private image. If needed, supply `--sleep-theme /path/to/Line.pbt` from your own stock backup. No original graphics are distributed in public firmware artifacts. The output folder linux must not already exist. The assembler checks the known factory layout, original bootloader regions, calibration and image checksums. If it rejects your factory data, this build is not qualified for your unit; do not override checks. Allow roughly 16 GiB free beyond the source dump.

Verify the generated folder:

```bash
(cd /mnt/c/PB626/linux && sha256sum -c SHA256SUMS)
```

Keep both folders: stock (factory) and linux (new firmware).

## 6. Install Linux

> [!CAUTION]
> The next write operation replaces the primary bootloader, raw kernel and all of the original user partition. A faulty SPL can make FEL recovery unavailable. Never disconnect the cable or power off during writes.

If recovery is no longer running, repeat step 3 and note the **new** COM port. Close serial terminals. In PowerShell 7 (see step 4), set the actual port and run the read-only preflight:

```powershell
cd C:\PB626
$Port = 'COM12'
.\tools\Restore-PB626Fast.ps1 -Port $Port -BackupDir C:\PB626\linux
```

Continue only if you see **Preflight passed. No eMMC writes performed.**

```powershell
.\tools\Restore-PB626Fast.ps1 -Port $Port -BackupDir C:\PB626\linux -Write
```

The tool asks you to type RESTORE followed by the device's displayed CID (copy the exact text from the prompt). It transfers only changed 4 MiB blocks and checks the complete contents afterward.

Wait for **All three eMMC regions match SHA256SUMS.** Only then turn off the reader, disconnect USB and turn it on normally. The native desktop should start without the PC. Hold Menu for one second and release to refresh the E Ink screen.

## 7. Restore the original factory system

Repeat step 3 to boot recovery. Close serial terminals and open PowerShell 7. Use the original stock folder, not linux:

```powershell
cd C:\PB626
$Port = 'COM12'
.\tools\Restore-PB626Fast.ps1 -Port $Port -BackupDir C:\PB626\stock
```

When the read-only preflight passes, run:

```powershell
.\tools\Restore-PB626Fast.ps1 -Port $Port -BackupDir C:\PB626\stock -Write
```

Type the requested RESTORE confirmation and wait for **All three eMMC regions match SHA256SUMS.** Turn off, disconnect USB, then boot normally. The original system and backed-up user files should be restored.

The same procedure restores a verified working Linux dump: substitute that backup folder. Legacy dumps without pb626-emmc-cid.txt require the original card's CID via -ExpectedCid in both restore commands (and --expected-cid for the offline builder). Never override a different CID or geometry.

## Optional: try the desktop without flashing

Download pb626-megi-eink-desktop from the same successful firmware run and extract it to C:\PB626\desktop. Enter cold FEL as in step 3, then from Windows PowerShell:

```powershell
cd C:\PB626
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\desktop\Start-PB626.ps1 -BundleDir .\desktop -Distro Ubuntu -Variant elan-display -Profile standard
```

Find the actual Linux COM port. In PowerShell 7:

```powershell
$Port = 'COM12'
.\desktop\Start-PB626Desktop.ps1 -BundleDir .\desktop -Port $Port -Waveform C:\PB626\default.wbf
```

Both MMC hosts are disabled in this mode. Use your verified factory waveform from step 5. Hold Menu for one second and release to manually reset the display. Turn off to leave RAM mode.

## If something goes wrong

- **No FEL device:** power off fully, use a data cable, repeat Menu + USB; confirm usbipd list.
- **No COM port:** do not run backup or restore. Re-enter cold FEL; verify the correct bundle and WSL distro.
- **Backup/restore error:** do not flash or reboot into a partially written system; keep the connection and original backup, record the error and seek help.
- **Checksum, CID, geometry or calibration mismatch:** stop. These checks protect the reader; do not disable them.
- **FEL unavailable after an interrupted write:** independent hardware recovery is not established for this board.

The FEL recovery console is intentionally unauthenticated and requires physical access. The native USB console uses getty/login: log in as root using the password chosen during offline image assembly. The native desktop runs as reader; Settings → Administrator prompts for the root password. Never expose a recovery console to an untrusted host. For support, provide the model, build commit, step and sanitized error in [Issues](https://github.com/BlackF1re/pb626-linux/issues). Never attach raw dumps, CID, credentials or private calibration. [Recovery format and safeguards](../scripts/restore/README.md).

### Debian 13 native candidate

For the Debian candidate use the complete `pb626-native-debian13-armhf`
artifact instead of `pb626-native-system` with the same offline image builder
and validated original backup, SPL and waveform. Do not mix kernel, DTB,
modules or manifests between artifacts. The candidate replaces p1 just like
Alpine; back up user data first. It has its own image identity, systemd and
APT, and is not yet a hardware-qualified replacement. Keep FEL recovery.
See [DEBIAN-MIGRATION.md](DEBIAN-MIGRATION.md).
