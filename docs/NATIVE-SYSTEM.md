# Native system administration

Only the persistent eMMC desktop gets the full Alpine base. The FEL
recovery image and RAM desktop keep their prior boot paths and package
budget. The native root boots read-only, runs fsck and remounts through
stock OpenRC. BusyBox PID 1 stays in place.

| Runlevel | Services |
| --- | --- |
| sysinit | devfs, dmesg, mdev, hwdrivers |
| boot | modules, hwclock, fsck, root, localmount, hostname, sysctl, bootmisc, syslog, klogd, networking (loopback), zram-init |
| default | pb626-board, pb626-desktop, pb626-usb, pb626-console |
| shutdown | killprocs, mount-ro |

Use `rc-status -a`, `rc-service pb626-desktop restart`,
`rc-service pb626-console status`, `rc-update show`, `reboot` and
`poweroff`. The desktop and getty use supervise-daemon. No desktop
dependency on Wi-Fi or USB. Device discovery uses mdev/hwdrivers; Lima
remains blacklisted. Logs rotate at 256 KiB with two backups; renderer
messages also go through syslog; Xorg diagnostics are volatile under /run. Inspect /var/log/messages.
64 MiB logical zram uses the kernel's default compressor and no eMMC
writeback. This is not 64 MiB of reserved physical RAM.

## Access and settings

The offline installer provisions the root password privately. CI images
contain locked accounts. Native USB presents getty/login rather than a
root shell. Xorg and the renderer run with hardware access; all desktop
clients run as reader (UID 1000), with a root-owned Xauthority cookie.
The reader account is initially password-locked but can run the local
desktop. The owner can set a reader password using `passwd reader`.
The Settings app (Tcl/Tk, on demand only) provides frontlight, Wi-Fi,
system status, administrator terminal, Alpine time zone/hostname tools and orderly shutdown/restart.
A narrow doas helper validates privileged requests; arbitrary root
commands require the root password via su. No sudo/polkit/systemd or
permanent settings-manager process. Frontlight is saved on explicit
Apply and restored at boot, initially zero. Poweroff turns it off
without overwriting the saved brightness.

## Wi-Fi and time

ConnMan and its stock OpenRC service handle DHCP, reconnect, network
credentials and DNS. Initially disabled; Settings → Wi-Fi settings
starts it and enables Wi-Fi, then opens connmanctl for scanning and
authentication. Use `agent on`, `scan wifi`, `services` and
`connect SERVICE_ID`. Wi-Fi off stops the service and removes its
boot enablement. ConnMan persists known networks in /var/lib/connman.
Do not run the legacy RAM pb626-network script alongside ConnMan.
RTC is handled by hwclock; UTC is the initial time zone. Alpine
`setup-timezone` is available; confirm wall-clock accuracy and NTP
after Wi-Fi testing. ConnMan's time synchronization is not a hardware
validation of RTC.

## Applications and maintenance

The existing Matchbox/MC/NEdit/xterm/htop desktop remains. Native also
includes MuPDF X11 with a document chooser, Nano, Curl, CA certificates,
timezone data, Alpine's setup tools, APK and OpenRC. User files live
under /home/reader (Books, Documents, Downloads). Install or update
Alpine packages from its stable branch with `apk update` and
`apk add PACKAGE`. Back up first. Do not install a stock Alpine
kernel in place of the paired PB626 kernel, and do not treat apk as
a bootloader updater. The manually built Matchbox and project
executables are still not individually packaged APKs.

SSHD is not enabled. To use SFTP, set a reader password locally
(to unlock the account), install the owner's public key in
/home/reader/.ssh/authorized_keys with correct ownership and permissions,
then enable the stock sshd service. Root and password SSH are prohibited.
No keys are pre-generated in CI.

## Acceptance gates (on the actual late ELAN/eMMC reader)

1. Keep a verified current system backup and tested FEL rescue.
2. Build the paired firmware, check manifests and rootfs contracts.
3. Confirm ro root becomes rw after fsck; check every runlevel and logs.
4. Verify desktop launches as reader, keyboard, touch, full refresh,
   Xauthority, renderer restart, desktop stop/start, and memory usage.
5. USB login succeeds with owner password, rejects wrong passwords,
   reconnects after unplug; FEL still works.
6. Test frontlight restore and orderly restart/poweroff; check zram and
   /proc/swaps, free memory and log rotation.
7. Test Wi-Fi scan, WPA2, DHCP renewal, DNS, reconnection after reboot,
   Wi-Fi off, clock and optional key-only SSH/SFTP.
8. Open representative PDF/EPUB documents, measure peak RSS and OOM
   behavior. Do not enable suspend, automatic power-button/low-battery
   policy, charger-only boot, microSD or Lima until individually tested.

The offline installer still replaces p1: this change is not an in-place
migration/OTA system. No raw boot extents, board calibration or recovery
algorithm is modified by the new services.
