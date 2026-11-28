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

The native bridge reads axp20x-pek releases without another daemon.
The default short press freezes the last physically acknowledged packed
panel frame. The reconstructed stock effect is DimArea(WHITE), original
nibble order, Gaussian blur 3x3 (sigma 5, reflect-101), and the original
portrait/landscape sleeping-book bitmap. It writes into the existing IPC
frame, never draws an X11 window, and sends one GC16 update (no INIT or
same-level scrub). After unlock the bridge captures the actual X11 frame
again and updates directly from known sleep-frame history.
RandR rotation is mapped to panel coordinates for all four rotations.
Rotated capture uses full logical damage instead of portrait dirty tiles.
The current dummy Xorg configuration only advertises portrait; actual
rotation availability and input mapping require hardware qualification.

systemd-suspend.service requires pb626-sleep.service, which sends a
root-only bounded IPC request, waits for the physical ACK before
sleep.target, and lets kernel system PM synchronously park the E Ink
controller and shut down its supplies. No fixed userspace sleep delay.
Its stop-post requests the bridge's acknowledged restore transaction after resume or failure. Power
key s2idle, xidle, Settings and normal systemctl suspend use this path.
The short power press uses the same systemd transaction instead of
preemptively locking the screen. A pending system sleep suppresses
additional power-key toggles; resume
drains queued wake-key events, resets X idle time and restores the saved
frontlight/LED policy after ACK. Convenience lock alone still unlocks
with the next short press. Direct /sys/power/state writes bypass this.

The stock Line.pbt is not distributed. The offline Debian installer
extracts both resources from the private preserved stock p8 and checks
the original theme and resource SHA-256 hashes. Existing installations
can use scripts/pb626_sleep_theme.py with their own original Line.pbt
and install the resulting files in /lib/firmware/pb626/. Missing
resources yield blur only, with a log warning. The C filter matches the
OpenCV 4.x reconstruction; exact 2.4.13 rounding is not yet qualified.

The existing /etc/pb626/suspend-qualified gate remains for Settings,
power key and idle timer; do not create it before real wake testing.
Explicit root systemctl suspend also requires the qualification marker,
a running bridge and its ACK.
Verify key, timer, non-power wake, repeated cycles, suspend failures,
panel power shutdown and actual s2idle current. This is a convenience
lock, not authentication. Deep sleep needs a resume-aware SPL.
The AXP209 emergency hold is unchanged.

The published PocketBook Platform_A13 source (Kernel/arch/arm/mach-sun5i/pm/pm.c)
maps factory pm_para standby_mode=1 to NORMAL_STANDBY for standby and
SUPER_STANDBY for mem/bootfast; partial uses NORMAL_STANDBY. The supplied
FEX contains that exact value. This establishes the BSP policy, not the
actual frequency of deep suspend in the proprietary UI. The factory MMC
host drives PE4 low before probe, toggles PG0 interrupt levels, preserves
MMC2 power and conditionally preserves external card power on partial and
standby. The experimental DT uses a fixed-regulator startup delay of 20 ms
as a conservative trial, not a measured factory delay. Settings > System
can mount a detected SD card at /media/sdcard or eject it; the helper checks
the actual MMC0 host and SD type and never formats media. Eject before
physical removal. ext4 preserves existing Unix ownership. No automount
or extra daemon. Firmware tests do not establish SD I/O or suspend stability.

### Board resource policy

The factory FEX declares 512 MiB, while measured stock MemTotal is 223036
KiB and the board has been observed as 256 MiB. Do not expose unverified
addresses by extending the memory node. The 32 MiB CMA is reusable by
normal movable pages; it is not a permanently lost 32 MiB. The video
engine is already disabled. Confirm physical DRAM and MemTotal/CmaFree
on hardware before changing the DT or reducing the eight DMA buffers.
The board service restores the CPU driver's actual min/max OPP range
and a conservative responsive ondemand policy (30 ms or kernel minimum,
75% up threshold, sampling_down_factor 1). User governor selection is
preserved. No new clocks, voltages or unsupported OPPs are introduced.
The bridge and its worker inherit nice -3 and existing OOM protection;
ordinary GUI clients do not. Avoid setting MemoryLow on the entire
session cgroup because that would also protect a large browser.
Targeted timer slack coalesces background service wakeups without
adding delay to the E Ink renderer, UI or network application threads.
GTK/X11 defaults retain all 16 panel levels for content.

## Power-off screen and battery safety

Settings > Display opens an on-demand unprivileged image picker. It
supports cropping, rotation and zoom; it generates a portrait 758x1024
image dithered to the 16 physical gray levels. The privileged helper
accepts only an exact-size raw grayscale stream on stdin and atomically
writes a root-owned PGM. There is no privileged image decoder or resident
picker. No selection means a white screen. A poweroff.target oneshot
runs after desktop shutdown (not on reboot), uses the standalone renderer
with GC16 scrubbing. The paired kernel attempts synchronous Runtime PM
on renderer close and also parks the controller at device shutdown.
Verify the ordering and shutdown time on real hardware.

Settings > Power configures low battery warning (default 10%) and
critical shutdown (default 3%). power_supply change uevents request a
bounded systemd oneshot, with a coalesced one-minute fallback timer.
The warning is an on-demand X11 message; no resident notification daemon.
Critical poweroff requires two low samples at least ten seconds apart,
a single valid battery in Discharging state and no reported online
external supply. Unknown telemetry fails safe; poweroff uses PID 1, not
a direct PMIC cutoff. The physical AXP209 emergency hold is unchanged.
Verify real battery/charger telemetry and poweroff before relying on it.

## Physical button bindings

Settings > Buttons > Advanced button bindings assigns separate short,
long and double actions for Left, Right, Home and Menu. Ordinary X11
keysyms go to the currently focused window, not a particular launcher
or application; refresh, keyboard toggle and frontlight are platform
actions. The privileged helper accepts a fixed allowlist, not commands.
The bridge waits for a second click only when one is configured; keys
with only a short action retain repeat. The old defaults and no-touch
pointer fallback remain, and the power key retains its separate
qualified suspend policy. Keyboard toggle uses the existing Matchbox
protocol; alternative sessions can bind a normal key instead.

## Native compiler qualification

The ARMhf compiler audit runs in the Debian 13 target userspace under QEMU
and checks each candidate against the existing renderer and charger tests.
It reports stripped file sizes, GNU size columns, ELF attributes and load
segments. It does not measure Cortex-A8 timing, physical display behavior
or resident memory.

Baseline audit (GCC 14.2.0-19, CI run 46083018733, 36 passing candidates):

| Profile | E Ink worker text | X11 bridge text | Charger text |
| --- | ---: | ---: | ---: |
| Baseline | 24089 | 34642 | 10920 |
| Cortex-A8 tuned | 24081 | 34698 | 10904 |
| Cortex-A8 -O3 | 28453 | 47994 | 11836 |
| Cortex-A8 -Os | 16016 | 28949 | 9996 |
| Cortex-A8 -Os with section GC | 15720 | 28711 | 9668 |
| Debian hardening | 24852 | 36017 | 11904 |

Values are GNU size's text column in bytes, not measured PSS. Debian's
compiler already defaults to ARMv7-A hard-float and Thumb-2. Cortex-A8
tuning and LTO do not demonstrate a general advantage here. Keep the worker
at -O3 and the bridge at -O2 with NEON until on-device timing is available.
The charger is predominantly event-driven and can prioritize code size.
The native build uses Debian's CPPFLAGS/CFLAGS/LDFLAGS, with the selected
optimization level overriding the distribution default; tests use matching
release flags. The exact combined compact charger profile is a required
CI candidate, not a hardware qualification.

Full qualification run 46084101571 confirmed the 4 KiB linker alignment
for all three native executables under ARMhf QEMU. The production build now
uses -Wl,-z,max-page-size=4096 and checks the PT_LOAD alignment, non-executable
GNU_STACK and GNU_RELRO. This is specific to the PB626 4 KiB kernel; the
ordinary Debian packages and Xorg DDX retain their distribution alignment.
The stripped sizes fell from 201984 to 83200 bytes in total (58.8%).
This is a file-size reduction, not a measured PSS saving.

For physical comparison, run identical full and partial updates and input
workloads at equal temperature, CPU governor, visual depth and waveform.
Record CPU time, preparation latency, PSS, and the first-update latency
after idle. Do not use elapsed QEMU compilation or test time as evidence of
Cortex-A8 performance.

### Remaining physical qualification

The patched Matchbox clients use the same 4 KiB linker alignment while
retaining their -O2 production compiler setting. The ARM build chroot
includes Xvfb only for smoke tests; it is not added to the shipped rootfs.
The compact -Os/section-GC alternatives are built and smoke-tested
separately. Their text reductions in run 46084101571 were 3151 bytes
(keyboard), 1905 bytes (panel), and 260 bytes (battery applet), before
changing alignment. Their input latency and PSS are not yet measured.

The compiler audit artifacts contain the actual ARM test executables for
both the release and candidate builds. Run only the following CPU-only
benchmarks on the reader as an ordinary user, with the same CPU governor,
temperature and load. Do not use the X11 capture regression against the
live desktop; that regression paints its test pattern on a virtual root.

- Set PB626_BENCH_TRANSITIONS=1 when executing the test binary from
  release/pb626-epd and packed-transitions/pb626-epd. Compare the reported
  renderer size and ns/frame for identical patterns and render styles.
  The optional nine-bit representation removes 679168 bytes of transition
  storage (663.25 KiB), without changing the shared frame protocol.
  Retain the 16-bit release representation until scan preparation latency
  is measured and actual panel updates are qualified.
- Set PB626_BENCH_RGB565=1 when executing the X11 bridge release test.
  Compare the current conversion and the candidate 64 KiB LUT on binary,
  gray and color data. Only select the LUT if the measured gain is
  worth the additional memory.
- The 32/64/256-row capture alternatives are checked against full-frame
  references in both 16- and 24-bit Xvfb visuals. Compare real bridge
  preparation times with the same X11 workload before selecting a
  different strip size; the production setting remains 128.
- Record pb626-profile-memory with the same services, frontlight,
  documents, temperature and idle interval. Record PSS, MemAvailable,
  CmaFree, reclaim/PSI and zram counters; use xrestop to separate server
  pixmaps. Compare with both a cold and warmed-up desktop.
- DMA release and the shared DDX remain qualification-gated. Verify
  repeated first updates after idle under memory pressure, scanout
  stability, both display depths, rotation, input and recovery before
  enabling them. Do not shrink CMA or the eight-buffer queue or change
  panel timing to chase a smaller memory figure.
- Compare governor, runtime PM delay, zram policy and allocator settings
  individually on hardware. Keep existing defaults absent measurements.
  Preserve user-session D-Bus, the keyboard daemon and independent client
  restart behavior unless profiling demonstrates a meaningful advantage.

The full firmware qualification and compiler experiments do not replace
physical A13 boot, E Ink and power/recovery checks.

### Follow-up compiler and RGB565 audit

The RGB565 scalar path uses exact 5-bit and 6-bit channel expansion tables
(96 read-only bytes total), preserving the NEON binary-pixel fast path and
all color/tone/gamma semantics. The arithmetic path remains available as
`PB626_RGB565_ARITHMETIC` for comparison; the compiler audit produces a
`rgb565-arithmetic/pb626-x11-epd/test` alongside the normal release test.
Run both with `PB626_BENCH_RGB565=1` on the reader. The full 64 KiB LUT is
still experimental; do not select it from emulator timings. The quantization
table is initialized phase-by-phase, avoiding strided stores without changing
its contents. Exhaustive RGB565 tests compare all 65536 values against the
independent channel reference for every profile, two tones and two gammas.

The compiler audit also builds release-tune and release-lto with the exact
release hardening and 4 KiB alignment. The private Matchbox clients and their
compact alternatives inherit Debian's CPPFLAGS, CFLAGS and LDFLAGS; they
retain their existing release optimization levels. Requalify the ARM X11
smoke and full firmware after changing these flags. No target speedup is
claimed without physical measurements.
