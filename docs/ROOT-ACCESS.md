# Root access on stock U626.5.20.1157

The exact stock firmware reported by the owner is `U626.5.20.1157`, running
Linux 3.0.8. The early 2018 `sudo ./calibrate` test was denied by sudoers.
Do not downgrade firmware to recover this older behavior.

The PBJB v8 thread lists Touch Lux 3 / PB626 as supported, and a user
specifically reported that their PB626 jailbreak failed on `626.5.14.791`
but worked after updating to **`626.5.20.1157`**:

- https://www.mobileread.com/forums/showthread.php?t=325185&page=9
- https://github.com/ezdiy/pbjb/releases/tag/v8

This is evidence from another user's device, not a guarantee about this unit.
PBJB installs a setuid-root helper on the persistent `/mnt/secure` filesystem,
and the vendor boot scripts may load it. The `@Jailbreak` launcher may reboot
when successful. This has more risk than read-only diagnostics, but much less
storage scope than flashing the system or bootloader.

## Preparation

- Preserve user-accessible book data, KOReader settings and other files on a PC.
- Confirm that the battery is adequately charged.
- Obtain the v8 release ZIP from the maintainer's release page, inspect it,
  and copy the two supplied `.app` launchers into `applications` on the reader.
- Launch **only** `@Jailbreak` through the reader's application menu. Do not
  launch `@Services` yet; the existing KOReader SSH server is enough for a
  root test once the helper is present.
- Do not press the launcher a second time blindly: upstream documents that
  running it again can remove the jailbreak.

After a successful install and reboot, connect through the existing KOReader
SSH server and inspect:

```sh
ls -l /mnt/secure/su
/mnt/secure/su id
```

The expected success criterion is `uid=0(root)` for the second command.
If root is unavailable or the reader behaves unexpectedly, stop and preserve
the error text. Do not attempt firmware flashing or raw-device writes.

Full eMMC backup follows only after root is verified. Because `mmcblk0boot0`
and `mmcblk0boot1` currently lack `/dev` nodes, they need separate treatment
before their contents can be copied. The backup must stay private; do not
upload any raw image to a public GitHub repository.

PBJB changes persist in `/mnt/secure`. Firmware upgrades may conflict with
immutable startup scripts; consult the upstream uninstall procedure before
any stock firmware update.
