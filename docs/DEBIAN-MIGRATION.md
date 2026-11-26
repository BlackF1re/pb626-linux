# Debian 13 armhf native system

The first migration candidate is built independently from the paired
Megi kernel-stage artifact by `scripts/build-debian-rootfs.sh`. It
uses mmdebstrap minbase and Debian trixie, updates and security repositories.
It does not copy Alpine userspace or the static RAM worker into Debian.
The rootfs is for eMMC, not initramfs.

## Build and installation

The existing firmware workflow publishes the candidate as
`pb626-native-debian13-armhf` alongside the last compatible Alpine
native and FEL artifacts. The artifact has the same validated offline
installer input names (rootfs tar, raw kernel, native DTB, KERNELRELEASE,
BUILD-COMMIT, SHA256SUMS), plus the resolved kernel config, package list and
`pb626-runtime_armhf.deb`. The offline image builder accepts the new explicit
Debian identity and checks its systemd init and runtime package before
assembling a private image. Follow INSTALL.md; use the matching artifact
and original factory WBF. Do not run the native DTB under FEL or overwrite
factory partitions. The installer still replaces p1; back up books and
settings before migration. Keep the proven recovery image independently.

On a Linux x86_64 build host with ARM binfmt and the workflow's dependencies:
```sh
bash scripts/build-debian-rootfs.sh kernel-stage debian-dist
```

APT and dpkg own ordinary programs. The PB626 worker, bridge, hardware
units, existing settings and patched Matchbox panel/keyboard are installed
as pb626-runtime. A separate disposable ARM build chroot is used for
compilation and tests. No GCC compiler or QEMU executable is in the final root; the Debian
x11-xserver-utils dependency on cpp is retained.
The patched clients live in a private PATH directory; the stock Debian
Matchbox packages own their data and unaffected applets. No new shell,
display manager or compositor is introduced.

## System administration

- PID 1: systemd 257, udev, D-Bus, cgroup v2. The desktop, board state and
  USB gadget use native systemd units. The stock serial-getty is activated
  by udev when ttyGS0 appears; no unauthenticated native shell.
- Use systemctl, journalctl, hostnamectl, timedatectl, apt and dpkg.
  The existing reader user stays unprivileged and joins netdev only for
  access to iwd. Xorg and the hardware bridge retain the device access they
  need. The narrow doas helper controls board frontlight, power and enabling/
  disabling the standard iwd service. No ConnMan or custom DHCP client.
- iwd provides DHCP, IPv4/IPv6 routes and DNS integration with
  systemd-resolved. iwctl and the packaged iwgtk (no indicator daemon)
  provide CLI and on-demand graphical network management. Settings enables
  iwd persistently and unblocks WLAN; Wi-Fi Off blocks it and stops/disables
  iwd. D-Bus activation permits direct client use. Do not run another network
  manager alongside it. Wi-Fi recovery and radio power need device testing.
- `systemctl enable --now iwd`, `iwctl`, `resolvectl status`,
  `rfkill list`, `journalctl -u iwd` are the ordinary diagnostics.
- Journald is persistent with 8 MiB disk and 4 MiB runtime targets. Zram
  uses the packaged generator (128 MiB logical, LZ4, priority 100).
  /tmp is on eMMC; zram uses page-cluster=0 to avoid swap readahead.
  No new arbitrary RAM cgroup hard limits.
- APT Recommends/Suggests and background update timers are disabled by
  default; manual security upgrades remain available. No network wait-online,
  SSH server, nftables rules, or unused GUI daemon starts by default.
  For optional SSH, provision keys with ssh-keygen -A, configure reader's
  authorized_keys and enable ssh.service; password/root SSH stays disabled.
- The systemd backlight template is masked so the board-specific frontlight
  power sequence remains authoritative. Automatic power-key and idle
  suspend actions are disabled until tested. Lima remains opt-in.
  No change to panel timing, voltage, waveform or eight DMA buffers.

## Kernel compatibility

The common kernel checks FHANDLE, POSIX timers, tmpfs and ext4 ACL/xattrs,
autofs, KCMP, keys and iwd's AF_ALG hash/skcipher algorithms and PKCS8.
The legacy uevent helper path remains empty, while the independent rescue
can still use its existing device discovery. BPF remains disabled; optional
systemd BPF restrictions are not relied on. No new physical board devices.
The Debian firmware-realtek package must supply rtl8188eufw.bin; verify
actual Wi-Fi firmware and driver compatibility on the device.

## Hardware acceptance before changing the default

1. Test native boot, authenticated USB ACM, root password, eMMC, reboot/
   shutdown and independently booted FEL rescue. Keep current backups.
2. Verify ELAN, buttons, frontlight, Matchbox keyboard/panel, all grays,
   E Ink recovery after worker crashes and normal refresh latency.
3. Test iwgtk and iwctl scan/connect, credentials, DHCP renew, DNS,
   IPv4/IPv6, reboot reconnect, rfkill, nftables and optional VPN.
4. Test package operations, PDF reader, file manager, terminal, OOM behavior
   and zram. Run pb626-profile-memory on each image with the same kernel,
   workloads, services and screen state. Compare MemAvailable, PSS, PSI,
   idle power, time to desktop, and refresh latency.
5. Only after these checks switch the default native artifact. Replace
   the Alpine RAM recovery separately when a Debian minimal rescue
   can meet the strict unpacked RAM budget and restore independently.
   A Debian desktop initramfs is not expected to fit the current 130 MiB
   unpacked RAM desktop budget; native eMMC has no such constraint.

Packed pixel buffers, transitions, XShm strips, RGB565, LUT packing, NEON,
runtime DMA release and a shared framebuffer remain separate experiments.
Suspend/charger-only UI, low-battery shutdown, pstore and in-place OS
upgrade/rollback require hardware qualification. The native kernel/DTB
and module set must remain paired; do not install an unrelated Debian
kernel expecting it to boot this board.

## Low-memory graphics profile

The Debian Xorg default is RGB565 (depth 16), with a 4096 KiB dummy
video aperture, MaxClients 64 and no automatic GPU binding. Composite
and GLX stay disabled. This is a true-color input format, not a binary
panel mode; the existing 16-level grayscale and waveform path is retained.
The Alpine fallback keeps its original Xorg configuration. If a client
requires depth 24, use a systemd drop-in for pb626-desktop.service:

```ini
[Service]
Environment=PB626_XORG_DEPTH=24
```

Restart the desktop or reboot. This also gives an A/B comparison with
identical applications. MALLOC_ARENA_MAX=2 is scoped to the desktop
service (glibc); it is not an artificial memory limit.

The bridge captures 128-row strips with one-row contrast halos. Both
RGB565 and RGBX use direct pixel decoding, preserving the reference
color conversion and global dither phase for a static frame. The XShm
segment and luma scratch are bounded by 130 rows; the XGetImage fallback
is bounded too. Logical desired/acknowledged levels, worker history and
saturated ghosting counts use four bits each. IPC, persisted state file,
PIN32, DMA queue, waveform and panel timing remain unchanged. Approximate
additional storage reduction versus the old 32bpp full-screen capture:
4.25 MiB for framebuffer + XShm, 0.65 MiB for luminance scratch and
1.48 MiB for four logical arrays. These are capacities, not measured PSS.

Use xrestop on demand to attribute server-side pixmaps to clients, and
pb626-profile-memory to compare equal idle/workload states. Do not count
shared-memory PSS twice. Keep packaged Xorg for security updates; custom
DDX, transition-map packing, LUT packing and idle DMA release still need
measured latency and hardware qualification. Do not delete the working
recovery or change the default boot artifact until the candidate passes.

## Device settings and hardware boundaries

The on-demand Tk control centre has Display, Buttons, Network, Power and
System tabs. Frontlight brightness is 1–100 percent, with independent
on/off state and last nonzero brightness saved atomically. The native DTB
interpolates the existing eleven duty points to 101 steps. The first boot
uses the safe hardware off default; a desktop/service restart never forces
the light off. Shutdown can physically remove power, but never overwrites
the stored setting. The tested PWM pin-disconnect sequence is unchanged.

Left/right can produce arrows or PageUp/PageDown, Home can toggle the
keyboard or send Home, and Menu can send Menu or Escape. A long Menu press
still forces a full refresh; touch failure retains hardware pointer fallback.
The gray profile and 16/24-bit visual can also be selected. Settings are
validated by a narrow privileged helper and loaded by systemd from a
root-owned EnvironmentFile. Desktop changes require a session restart.
CPU governors are validated against the actual kernel's available governors
and restored on boot. Power key policy uses logind (ignore or poweroff), takes effect next boot.

Idle suspend is disabled by default. ONLY after real suspend/resume testing
(including frontlight, E Ink and USB wake) may the administrator create
/etc/pb626/suspend-qualified as root. This unlocks manual suspend and an
optional xidle timer (5–60 min), never an unconditional light-off timer.
Removing the marker blocks suspend even if an earlier setting remains.
The PMIC's hardware emergency long-press action is not changed by logind.
Battery, charging telemetry, RTC, temperature and LED state are exposed
read-only in System. No charging thresholds or regulator settings are
invented. microSD, Lima, charger-only boot and suspend/resume are not
qualified; SPI NOR remains unconfirmed. See HARDWARE-PROFILE.md.

The bridge now also uses a three-row rolling luminance window (2274 bytes)
inside each bounded XShm strip, replacing the 98540-byte scratch array.
The parent waits for Xorg/session or bridge exit with Bash wait -n on Debian,
removing a one-second process-existence polling loop. Xvfb regressions cover
16/24-bit full and partial captures against the original full-frame reference.

Brightness changes in the centre preserve the independent light switch
and save on slider release (or the Save brightness button), not on every
motion event. The single board GPIO LED can be switched on/off and its
setting restored at boot. System includes hostname and NTP controls via
hostnamectl/timedatectl. Tk fonts use proper family-list syntax; the GUI
smoke test actually creates the five tabs under Xvfb rather than checking
only Tcl completeness.

## Stock feature parity and remaining qualification

The owner's stock archive contains an embedded Linux 3.0.8 Kconfig,
ELAN/alternative touch modules, RTL8188EU/alternative Wi-Fi modules,
Mali/UMP, a 50 MiB zram setup, Android USB mass-storage and developer
RNDIS scripts. It also contains a squashfs resource image and vendor UI.
The factory WBF matches the existing validated digest. Do not import the
proprietary stock binaries, device data, or waveform into the repository.
The current native port intentionally provides authenticated USB ACM,
not a Windows file-transfer interface; exporting the mounted ext4 root
as USB mass storage would risk corruption. Qualify an on-demand USB
network or MTP transfer mechanism separately. MicroSD, suspend/resume,
charger-only boot and GPU acceleration remain unqualified. A successful
firmware build is not a substitute for testing these features on hardware.

Stock Xorg's Debian package pulls GBM/Mesa/Gallium/LLVM through package
relationships even though the Xorg executable does not directly link
Gallium/LLVM. Do not delete these libraries or bypass dpkg dependencies.
GLX is disabled at both extension and module levels; verify Xorg maps/PSS
and both visual depths on the reader before making any size or RAM claim.
GTK3 is required by stock matchbox-desktop; GTK4 by iwgtk (on demand).


## Experimental external microSD profile

The factory script.bin mmc0_para enables a four-bit bus on PF0–PF5;
MMC0_enable describes PE4 power and PG0 detection. Megi's board DTS
already maps these to a fixed 3.3 V regulator (PE4 active low) and a
PG0 active-low card detect. Previous hardware attempts stalled I/O, so
normal native and both FEL DTBs stay unchanged. The Debian artifact
also contains pb626-elan-emmc-native-sd.dtb and pb626-raw-linux-sd.img.
These opt-in files enable MMC0 at at most 12.5 MHz, without 1.8 V switching,
write-protect, SDIO or MMC probing. VFAT and exFAT are modules.
Use build-native-image.py --experimental-sd in addition to the usual
arguments, only with an independent verified FEL backup. Start with no
card, then insert a backed-up FAT32 card and verify enumeration and read
I/O before any write. Keep the normal image as a rollback. This profile
is not a claim that the earlier physical stall is fixed. Do not format
or repair any device until its MMC0 host identity is checked.


## Short power-key lock and sleep policy

The native bridge reads axp20x-pek releases without another resident daemon.
The default short press locks keyboard/pointer and physical navigation, then
applies a lightening filter and a small lock glyph to the existing packed
frame. This is an original visual approximation, not the proprietary stock
filter or a password lock. The physical frame is frozen after ACK; the
frontlight is temporarily disabled and PE8 uses a slow timer blink. A short
press restores the screen and configured frontlight/LED policy. The normal
LED default is heartbeat. A GPIO LED cannot provide a hardware breathing
waveform and software blinking stops in actual suspend. Ignore and poweroff
are also configurable. The s2idle choice is gated by /etc/pb626/suspend-qualified;
never create this marker before physical wake testing. A failed sleep request
leaves the reader locked but awake. Non-power wake leaves the visual lock in
place until a short power press. The AXP209 emergency hold is unchanged.
The bridge is an input convenience lock, not a security boundary against
other X11 clients. Deep sleep is not enabled: SUN5I_PM requires a resume-aware
SPL, while BT0-uncaged currently reconstructs a fixed cold-boot SPL.
