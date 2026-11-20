# FEL/microSD lab boot: observed state

This record is based on the owner's transcript of an earlier local build.
It documents test observations, **not** files currently available in this
repository. The source workspace was `/root/pb626-lab` in the `XperiaDev`
WSL distribution. Its build scripts, kernel image, DTB and initramfs must be
collected and reviewed before changing the implementation.

## Confirmed observations

- FEL entry works with the far-right physical Menu button.
- A kernel was delivered into RAM over USB FEL, without an eMMC flash.
- Alpine Linux booted with its rootfs on an external microSD. The earlier
  console reported `/dev/mmcblk0p1` as `/` **in the alternate kernel**.
  Block device numbering may differ from the factory kernel; prefer UUID.
- A USB gadget serial console appeared on Windows as a COM port, with VID/PID
  `0525:a4a7`. This is **not** the board-level UART.
- WLAN connected, SSH became available and Alpine `apk` could install
  packages. The previously described passwordless root SSH configuration
  should not be carried into a public release image.
- A monitor-mode experiment reported captured frames; this does not confirm
  packet injection.
- PTY and terminal environment were initially broken, then a subsequent
  diagnostic boot reportedly restored a usable shell, `ls` and `htop`.
- An E Ink module loaded, but no image appeared. Frontlight stayed visibly
  at maximum and writes to the tested brightness controls had no observed
  effect. Panel rendering and lighting remain **unverified**.
- microSD reads sometimes stalled. A lowered card clock was attempted;
  this did not establish long-term stability. The latest documented boot
  mounted the ext4 root read-only, and an unfinished journal was detected.
  The transcript ends during an offline filesystem check; its outcome is
  **unknown**.

## Immediate engineering priorities

1. Preserve the exact working local FEL boot tree and image provenance. Do
   not overwrite the only working kernel/initramfs while testing variants.
2. Complete and verify microSD filesystem recovery while unmounted. Keep
   `/` read-only until consistency is demonstrated, and image the card
   before further risky experiments.
3. Import sanitized, versioned loader/kernel/DTB/initramfs and SD-rootfs
   build recipes into this repository. Do not commit Wi-Fi credentials,
   passwordless SSH trust settings, host keys, raw block images or device
   secrets.
4. Reproduce the **known-working headless boot** in GitHub Actions, with
   immutable outputs and checksums. Keep the host-side FEL uploader separate.
5. Implement a proper E Ink refresh path using a validated panel waveform,
   then frontlight and ELAN touch/input.
6. Add a minimal E Ink-aware touchscreen shell only after reliable display
   refresh; cover suspend/resume after that.

## Boot boundary

Until a recovery route is demonstrably sufficient, **do not** write to
the factory eMMC, alter its partitions, change eMMC boot configuration or
replace the factory bootloader. The preferred development boot is FEL into
RAM plus a disposable/removable microSD rootfs.

The existing rootfs currently has a reported interrupted ext4 journal.
Do not run another write-intensive experiment on it before checking or
restoring the filesystem. Do not run fsck against a mounted read-write
filesystem.

## Host-side tool roles

Windows PowerShell remains the operator console. `usbipd` + WSL
`XperiaDev` may be used **only as the FEL USB transport/uploader** if
the current working script requires them; kernel/rootfs builds should
move to GitHub Actions. This does not require local compilation.

The earlier command sequence is preserved here as historical reference,
not a verified release procedure:

```powershell
# Power off reader; enter FEL while holding the far-right Menu button.
usbipd list
usbipd attach --wsl --busid <FEL_BUSID>
```

```powershell
wsl -d XperiaDev -u root -- sh -lc '/root/pb626-lab/try-fel-direct.sh'
```

`<FEL_BUSID>` must be replaced by a current bus ID. The existing
`try-fel-direct.sh` has not been reviewed here; do not execute
a modified/unrecognized copy. Windows gadget COM port identities may
change between boots.
