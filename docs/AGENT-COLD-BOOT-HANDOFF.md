# Handoff for the next on-device agent: cold boot from eMMC

This is a handoff for a **hardware experiment**, not a claim of successful
cold boot. Do NOT merge PR #4 or modify the factory bootloader until hardware
evidence proves the new boot path.

## Build provenance

- Repo: `BlackF1re/pb626-linux`
- Experiment branch: `experiment/stock-axf-uboot-chainload`
- Existing PR: https://github.com/BlackF1re/pb626-linux/pull/4
- Megi 7.2 + Alpine FEL bundle (successful):
  https://github.com/BlackF1re/pb626-linux/actions/runs/45002994505
  Artifact: `pb626-mainline-7.2-ram-bundle`.
  SHA-256 of downloaded ZIP:
  `b5c55c9979b45c9d89173eb5e670bb672a90fb99331155b1a7d23596edf8ddd2`.
- Standalone AXF-to-U-Boot experiment:
  https://github.com/BlackF1re/pb626-linux/actions/runs/45003395855
  Artifact: `pb626-stock-axf-chainload-experiment` (successful).
  SHA-256 of downloaded ZIP:
  `f2c5ce919692aab8ca9d5044c5afc73526dfcb84f6df68cf158958ccaabc09a5`.
  The previous run 45003183573 failed during DTB property deletion and
  MUST NOT be used.

Build provenance MUST be checked again at handoff time (run conclusion,
artifact checksum, source revision, matching kernel and DTB). A green CI
result does not establish on-device boot.

## Key evidence already observed by owner

1. PocketBook 626 Plus / Touch Lux 3, Allwinner A13, late ELAN revision.
2. Verified FEL/Megi 7.2 kernel + Alpine and USB ACM shell.
3. Prior on-device FEL session successfully mounted Alpine eMMC **p1**
   as rw root. In that session Linux used `/dev/mmcblk2p1`.
4. The owner subsequently restored the **entire factory image**, including
   all three eMMC storage areas, and verified SHA-256. **Therefore assume
   that Alpine p1 is NOT currently installed.** Recheck before booting.
5. Early factory stages: BootROM -> eGON.BT0 at user area 0x2000 ->
   eGON.BT1 from LBA 38192 -> /boot.axf from FAT p2 ->
   /linux/linux.ini -> /linux/bImage at 0x40008000.
6. The previous combined wrapper/U-Boot trial reached `bootz`, then
   apparently returned; there is no serial error text. A separate direct
   wrapper attempt also gave no observable Linux USB/heartbeat.

## What is built

`axf-chainload.yml` packages a standalone, SPL-less Megi `u-boot.bin`,
built for 0x4a000000, and a matching Megi `zImage` and ELAN eMMC `dtb`.
It is *not* a raw eMMC image or an installer.

Expected files in the standalone artifact:

- `linux/u-boot.bin`
- `linux/pb626-zImage`
- `linux/pb626.dtb`
- `SHA256SUMS`
- `README.txt`

Megi FEL bundle supplies:

- `pb626-megi-rootfs.tar.gz` for assembling p1 Alpine;
- `pb626-megi-zImage`, `pb626-elan-emmc-install.dtb` and FEL initramfs
  for the controlled installer/rescue environment;
- eMMC backup variant `pb626-elan-emmc-backup.dtb`.

**WARNING:** `scripts/install-pb626-emmc.sh` is still a **p8 installer**.
Its size/layout assertions and its raw filesystem image target p8.

## Prepared p1 kit

The two pinned ZIPs and their internal manifests passed SHA-256 verification.
The zImage is identical in both bundles. The standalone DTB enables the
internal MMC controller, selects p1, and has no initrd addresses. Alpine
contains the modules for `7.2.0-gfacc87117511-dirty`. The p1 installer
adds the matching PID 1 script and copies the verified factory waveform.

The local kit is `artifacts/axf-p1/pb626-axf-p1-kit.tar`. Its sibling
`factory-p2.img` is the original FAT partition extracted from the verified
user-area image. Its SHA-256 is
`237dd3c9930c9257a40652d7b4d5427d804748a865653f821551400fa075a21e`.
The stock `linux.ini` and `normal.ini` in that image are byte-identical.
The candidate keeps the CRLF endings and changes only the three keys in
`[segment]` in `linux/linux.ini`.

When the reader is available, confirm a normal factory boot, then enter
cold FEL and start the **full** RAM backup variant:

```powershell
& .\scripts\Start-PB626.ps1 -BundleDir .\artifacts\45002994505\bundle -Variant elan-emmc-backup -Profile diagnostic
pwsh -File .\scripts\Send-PB626AxFKit.ps1 -Port COM12 -Archive .\artifacts\axf-p1\pb626-axf-p1-kit.tar
```

Use the ACM port that actually enumerates. The sender places the kit in
`/run`, verifies it, and prints its directory. Reopen the serial shell,
change to that directory, and run these as separate steps:

```sh
sh install-pb626-axf-p1.sh check "$expected_cid"
sh install-pb626-axf-p1.sh install-root "$expected_cid"
sh install-pb626-axf-p1.sh stage-boot "$expected_cid"
sh install-pb626-axf-p1.sh activate "$expected_cid"
```

Set `expected_cid` from the verified backup's eMMC map. Before
`install-root`, verify the full user, boot0, and boot1 backups again.
The installer verifies the live BT0/BT1 contents, eMMC identity, geometry
and stock FAT files. `install-root` erases stock p1, installs Alpine and
checks ext4 and the installed files on readback. Stage the files and
activate the candidate only after each preceding step succeeds.

After activation, power off fully and start with the power button. Collect
the PE8 LED pattern and USB enumeration. On the ACM shell, check
`uname -r`, `cat /proc/cmdline`, `cat /run/pb626-boot.log`, and the
`/` entry in `/proc/1/mountinfo`. Match its major:minor to
`/sys/class/block/mmcblk2p1/dev` and check for ext4 and rw. If the test
fails, return to FEL, resend the kit and run
`rollback-boot` to restore the original INI. Restore the full factory
backup to recover the original FAT contents of p1.

On the ELAN unit, the RAM preflight matched the factory BT0, BT1, and FAT
files. Alpine was installed on p1, passed `e2fsck -fn`, and was verified
by a read-only mount. The three boot files and the selected INI passed FAT
readback. Cold boot requires independent confirmation through USB and the
root mount.

## Hardware-side plan (agent must execute carefully)

A. **Read-only preflight.** Confirm original factory firmware boots;
   reconfirm FEL access; locate the real eMMC by type/name/CID and partition
   start/length; verify the offline full user-area, boot0, and boot1 backups.
   Locate p2 FAT, p1 target, stock `linux.ini`/`normal.ini`; save all
   original p2 boot files off-device. Do not publish serials or secrets.

B. **Install Alpine to p1**, not p8, using the matching bundle's
   `pb626-megi-rootfs.tar.gz` and verified, board-specific firmware files.
   Preserve partition geometry; no raw overwrite of boot0/boot1/BT0/BT1.
   Ensure `/sbin/pb626-emmc-init` is executable and is the eMMC-capable
   `boot/init-megi` script, and `/etc/pb626-image-id` is
   `pb626-emmc-alpine-v1`. Check shell interpreter, Linux modules,
   permissions and filesystem integrity. Mount and verify p1 by FEL again.
   Optionally run a FEL kernel direct-root sanity test.

C. **Stage separate files to p2**, keeping `boot.axf`, existing
   `bImage`, stock `linux.ini`/recovery configurations and all
   calibration files backed up. Verify SHA256 and FAT readback before any
   change to the active boot configuration.

D. **Adapt the actual factory INIs only after inspection.** Linux-sunxi
   documents an alternate segment at 0x4a000000:

   ```ini
   [segment]
   img_name = c:\linux\u-boot.bin
   img_size = 0x80000
   img_base = 0x4a000000
   ```

   The quoted segment is an example only. Preserve other sections, line
   endings, recovery/calibration paths, original configuration and safe
   recovery. Ensure the size field conforms to the loader's semantics
   and `u-boot.bin` placement is actually accepted.

E. **Cold-boot diagnostic.** Record power LED and USB events. The default
   U-Boot command attempts `fatload` from MMC devices 1, 0 and 2, and
   executes `bootz 0x42000000 - 0x43200000`, with
   `root=/dev/mmcblk2p1 rootwait rw init=/sbin/pb626-emmc-init`.
   MMC numbering must be verified, not assumed. No serial UART is
   available without opening the reader.

F. **Rollback or continue.** If the experiment fails, use verified FEL
   rescue and restore the exact original INI and FAT files, then restore
   factory data as needed. For subsequent diagnosis, instrument early
   boot with independent AXP209 data-buffer or PE8 GPIO markers before
   and after `bootz`; lack of USB alone does not locate a crash.

## Exit criteria

- Real cold boot from factory BT0/BT1/boot.axf into Megi Linux 7.2.
- PE8 heartbeat and USB `0525:a4a7` ACM shell confirmed on-device.
- Alpine `/` is confirmed on eMMC p1 rw, modules and USB gadget functional.
- Factory rollback has been retested.
- Do not merge the experiment before these observations.

Do not re-run firmware installation blindly on a unit restored to factory.
