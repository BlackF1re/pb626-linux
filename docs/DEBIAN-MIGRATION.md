# Debian armhf migration and hardware acceptance

The intended native system is Debian 13 (trixie) armhf, not a Debian-themed
Alpine image. Keep the last known-good FEL/Alpine rescue independently
bootable until a Debian rescue image has passed the same recovery tests.
No default rootfs or installer format changes in this reliability series.

## Proposed native baseline

- Bootstrap a fresh minbase with mmdebstrap, APT and Debian's armhf glibc
  packages. Build both PB626 renderer programs against that target ABI.
  Copy matching kernel modules and required firmware, not musl binaries.
- Use systemd-sysv, udev, D-Bus, journald, serial-getty and standard
  systemctl/login tools. Keep the graphical session unprivileged.
  Use native units for PB626 hardware preparation, USB ACM configuration
  and the existing X11 session; limit start bursts and stop the entire
  service cgroup. Board-specific setup and renderer code still belong
  in the project; generic networking, logging and service supervision do not.
- Retain the current Matchbox UI, panel/keyboard E Ink changes, buttons,
  frontlight controls, file manager, terminal and reader. Use packaged
  Xorg and desktop utilities rather than copying an executable out of a
  package. Rebuild only necessary patched components. Do not introduce
  a new desktop shell or compositor.
- Evaluate iwd + iwgtk (both packaged for trixie armhf), with iwd's
  built-in network configuration/DHCP and a supported resolver backend.
  Use iwctl/iwgtk, D-Bus and the packaged iwd service. Do not run
  wpa_supplicant, ConnMan or NetworkManager alongside it.
  Debian's ConnMan uses xtables; the current nftables-only kernel is
  not a drop-in replacement for that backend. Test iwd and driver
  compatibility before choosing the final network stack.
- Preserve real APT management. Install without Recommends by default;
  disable unattended jobs/timers unless enabled by the owner.
  Keep package lists available when needed. No build toolchain on device.
  Keep journald bounded (initial proposal 8 MiB persistent, 4 MiB runtime),
  zram 128 MiB logical/LZ4, swappiness 100 and nftables/VPN on demand.
  Disable unused services, not generic kernel/user ABI features.
  Keep SSH opt-in and no credentials or machine identity in artifacts.
- Do not enable automatic suspend, charger-only mode, low-battery shutdown
  or pstore until hardware qualification. No repartitioning or changes
  to factory data, bootloader or panel voltage/timing.

## Build and kernel gates

Before the rootfs becomes a bootable candidate, check the actual final
kernel .config against systemd's Debian README and iwd's crypto checks:
devtmpfs, cgroups v2, FHANDLE, tmpfs ACL/xattrs, seccomp, netlink,
AF_ALG hash/skcipher, required algorithms and firmware loading.
Do not enable eBPF merely to silence optional systemd sandbox warnings;
verify actual service startup without it. Add only proven requirements.
Preserve the built-in E Ink driver and all eight DMA buffers.

Create a separate Debian native artifact; validate its image identity,
module release, glibc binaries and installer compatibility offline.
Keep the existing native Alpine image and USB ACM FEL artifact as
fallbacks. A Debian RAM rescue is a later separate measurement: its
unpacked size plus kernel/worker memory must fit, and it must restore
the reader without depending on the installed rootfs.

## On-device acceptance

1. Measure cold boot, idle MemAvailable, PSS and PSI with the same kernel,
   screen state and services. Compare to Alpine, not package download size.
2. Verify USB console/login, root password provisioning, shutdown/reboot,
   eMMC read/write, factory partition isolation and independent rescue.
3. Verify input, Matchbox panel/keyboard, frontlight, full and partial
   refresh, all 16 grays, temperature errors, intentional worker crash
   and repeated service restart. No timing/voltage changes.
4. Verify scan/connect/authentication, DHCP renewal, DNS, disconnect,
   reconnect after reboot, RF kill, nftables and optional VPN. Confirm
   no network daemon races and no plaintext credentials in logs.
5. Read PDFs, open terminal and settings, install/remove an ordinary APT
   package, stress memory and compare zram, OOM and refresh latency.
6. Only then change the default native artifact. Replace FEL rescue
   separately if its measured size and recovery reliability permit it.

## Optimizations requiring measurements

Packed 4-bit logical frame buffers, packed transition maps and ghosting
counters, smaller XShm strips, RGB565, rolling luma rows, LUT packing,
NEON and a shared framebuffer can reduce memory or processing time but
must be checked for equivalence and latency. Do not add overlapping
buffer savings. Physical PIN32 is not equivalent to an 8-bit index
for all factory drive states. Keep the eight-buffer queue; idle DMA
release and runtime power management require driver/hardware tests.
