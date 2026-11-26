# PB626 ELAN/eMMC kernel policy

The target is a 256 MiB single-core A13 Linux computer, not a generic A13
development board. The pinned Megi baseline is resolved through explicit
enable/module/disable requests in scripts/configure-megi-kernel.sh and
checked after olddefconfig, including when restoring a cached kernel.
Unknown or disabled options may disappear from the resolved Kconfig; the
negative checks reject both y and m. This is a shared kernel for RAM,
native and recovery; only the board DTB controls hardware binding.

## Hardware

- Keep the E Ink V4L2 driver, TPS65185, CMA, VB2, MBUS DMA, panel GPIOs,
  backlight, ELAN and power/thermal/RTC support built-in. No change to
  waveform, VCOM, panel drive, queue size, pin timings or charger logic.
  Future charger-only UI can use the built-in panel; recovery deliberately
  leaves it unbound, with the established PB4 off hog.
- Keep the internal EHCI/OHCI host and rtl8xxxu for Wi-Fi. External MUSB
  is gadget-only, with configfs CDC ACM and no mass-storage/other gadget
  functions. Recovery disables the internal host and I2C2, not the shared
  PHY or SRAM. No legacy touchscreen probes.
- Disable inherited video decoder, conventional display engine and SPI2
  in all normal DTBs. The possible NOR is unconfirmed on this eMMC unit;
  MTD, SPI NOR and the SPI controller are diagnostic modules, with no
  automatic probe. A separate diagnostic DTB can opt in if read-only
  hardware inventory justifies it. No regulator GPIO/polarity changes.
- Keep Mali active in native/RAM DTBs and DRM/Lima as modules; native
  autoload remains blacklisted, and explicit modprobe lima can test it.
  No standard sun4i DRM KMS, legacy framebuffer or fbcon; keep VT for Xorg.

## Memory and scheduling

The upstream default CMA DT pool was 96 MiB even though the kernel
fallback was 32 MiB. Both are now 32 MiB; the pool remains reusable and
within the lower 256 MiB. Do not shrink the eight V4L2 scanout buffers.
Measure CmaTotal/CmaFree and test repeated allocations under memory
pressure with and without Lima before reducing further.

EXPERT exposes BASE_SMALL (smaller core structures) and -Os (smaller
kernel code). Preserve the ordinary SLUB allocator: SLUB_TINY is
explicitly intended for <=16 MiB systems, sacrifices debugging and does
not suit this target. Stack protector strong, standard syscall/IPC,
namespaces, seccomp and module loading remain. Enable MGLRU for memory
reclaim and PSI for measurements; the LRU implementation can be compared
at runtime through /sys/kernel/mm/lru_gen/enabled. Keep debugfs and
existing memory/power/Wi-Fi debugging while the port is under development.
Keep memory, PIDs, fair CPU and block IO cgroup controllers; no eBPF
syscall/attachment, legacy device controller, RT group scheduling or
autogroup. Classic socket filters and normal networking are unaffected.
Native cgroup v2 limits can be applied separately; kernel support alone
does not create application memory limits.

Use HZ=100, NO_HZ_IDLE and high-resolution timers. Verify touch,
USB ACM and E Ink latency/refresh stability. Keep cpufreq/cpuidle,
thermal protection and suspend support. Native zram is 128 MiB logical,
LZ4, no backing disk, per-entry tracking, recompression or zswap. The
size is not preallocated; observe mm_stat and swap pressure rather than
assuming a fixed compression ratio. Existing swappiness=100 is retained
until measured.

## Network and storage

Stateful nftables with inet/IPv4/IPv6, NAT and common rules remains
modular. Remove legacy IP sets/xtables, protocol-specific conntrack/NAT
helpers, flow offload, multipath TCP and unused nft queue/OSF/forwarding
extensions. Keep WireGuard, TUN (OpenVPN), IPsec ESP/XFRM and IPv4/IPv6
policy routing for VPNs, on demand; no VPN or firewall rules are
automatically enabled by this change. ConnMan's nftables backend can
still use the normal NAT/filter primitives. No SCSI/USB storage, F2FS,
NBD, CUSE, autofs or unused sensors. Keep ext4 built-in and VFAT, loop,
FUSE as modules. The old SD and recovery eMMC safety conditions remain.

## Qualification

Compare the paired artifacts to the last known-good kernel:
- resolved config, zImage/module sizes, DTB CMA/status and module ABI;
- RAM desktop, authenticated native USB console and read-only FEL rescue;
- eight-buffer E Ink restart under memory pressure, frontlight and touch;
- Wi-Fi reconnect, IPv4/IPv6, nft inet rules and the chosen VPN;
- Lima explicit load/unload, memory pressure, thermal/charging telemetry;
- idle power and timer IRQ rate, zram mm_stat, /proc/pressure, meminfo,
  slabinfo and loaded modules after the same workload.

The firmware build checks policy, not physical hardware. Keep the last
verified recovery and native images until these checks pass.

## Debian 13 userspace compatibility

The native Debian candidate uses systemd and iwd. Keep FHANDLE, POSIX_TIMERS,
KCMP, TMPFS_XATTR, TMPFS/EXT4 POSIX ACLs and AUTOFS_FS for standard systemd
interfaces. The legacy UEVENT_HELPER_PATH is empty, firmware user-helper
fallback is disabled, and the independent FEL recovery remains supported.
Explicit keys, AF_ALG hash/skcipher, AES, ECB/CBC, HMAC/CMAC, MD5/SHA1/SHA2,
RSA and X.509/PKCS8 support cover the iwd kernel crypto contract. This is
not a reason to enable broad BPF or unrelated board drivers. See
DEBIAN-MIGRATION.md for qualification.
