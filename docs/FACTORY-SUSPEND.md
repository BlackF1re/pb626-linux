# Factory suspend/resume reverse-engineering evidence

Read-only analysis of the owner-supplied 5.20.1157 filesystem archive and
the separate first 68 MiB of eMMC. The raw dump and vendor code remain
private. Offsets below are evidence anchors, not patch addresses or a
flash recipe. LLVM ARM disassembly and ELF symbols/PLT relocations were
used; no physical sleep cycle was executed.

## Boot and memory identification

| Object | File offset / size | SHA-256 |
| --- | --- | --- |
| eGON.BT0 1.5.0 | 0x2000 / 0x5400 | 245b81edb1f1ffa51738f33548f793500f2fab9b00c150df9f1ee78b81667824 |
| eGON.BT1 1.5.1 (identical copies) | 0x12a6000, 0x12e6000 / 0x38000 | 3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227 |
| boot/bImage | raw ARM Linux 3.0.8+, 2013-06-20 | 0f902e9e6e5bc6307ccd73078f64049b2d2621cc05be5864802c42768e9f3b7a |
| boot/script.bin | FEX | 6133d6d7d3042d88d0b23b65490cc6a9f134002e0b0176e0dea51e51bdc09bc2 |
| SquashFS libhwconfig.so | ELF | 4aa21007769bffd83a1af101084fb05235c26e58c06316339356ac052bb5d705 |
| SquashFS libinkview.so | ELF | 9f08bfbfc6ac3d8cfed8e3e2c67eb6a81a728762a5cb10f1dab2c1977e9f0422 |
| SquashFS monitor.app | ELF | 3b731bdb5e4fa20b7a1ace80c0aba2830c53e8e942f60003daff360d8ab62037 |

Both eGON header checksums recomputed successfully. The two BT1 copies
are byte-identical. BT0 embedded DRAM parameters at 0x38 specify DDR3,
408 MHz, one rank, density 2048 Mbit, device I/O width 16, bus width 16,
CAS 9, size 256 MiB. The FEX differs (x8, size 512 MiB). The actual
BT0 header agrees with observed physical RAM. The on-disk BT1 header
(offset 0x4c) also contains x8 / 512 MiB, but this is not its runtime
configuration. BT0 0x4e88 reads the 80-byte block, selects direct
initialization or a geometry detection branch (0x4d04), and writes the
working values back into its own header via 0x1c18. That detection path
tries bus/rank configurations and probes memory aliasing, reducing
density when needed. On normal boot, 0x874–0x878 invokes 0x1c28, which
copies the resulting 80-byte block into the loaded BT1 header at
0x4240004c. This explicitly overrides the stale on-disk BT1 values;
script.bin and script0.bin remain generic inputs. The exact downstream
FEX/ATAG rewrite is not established by this observation. Do not copy
generic FEX geometry or unqualified timings into a working SPL.
Cold boot may detect geometry; retained resume must not repeat
destructive memory probing. Validate the live DCR against the observed
board and the paired kernel/SPL instead.

## Factory userspace and kernel

- libhwconfig.so device_suspend (0x5b38), platform 14 path: argument zero
  selects partial, nonzero selects mem in /sys/power/state. Temporarily
  changes the CPU governor to performance and back to interactive.
  That is not an appropriate modern generic CPUFreq policy.
- libinkview.so GoSleep (0x74d8c) checks player/audio/TTS/browser,
  scanning/recognition, charging/USB/USB host, network activity,
  Bluetooth activity, input/user action and pending E Ink updates.
  hw_ban_suspend uses monitor IPC; hw_sleep coordinates sensor and display.
- monitor.app do_suspend (0x28458): scans /proc/*/cmdline for login shells,
  tries a mutex, checks ban_suspend_for monotonic deadline, optionally
  sets an alarm, checks SD state and reads/writes /sys/power/wakeup_count,
  calls sync, saves/restores LED state, calls device_suspend at 0x288f0,
  and records sleep elapsed time. setalarm (0x36360) uses RTC operations.
  This demonstrates intended alarm use in stock, not a qualified wake
  source in the current DT/kernel.
- Kernel raw file offset 0x3aab0 distinguishes normal standby (type 1,
  copies a 0x27c8-byte SRAM payload, calls it) from super standby (type 3).
  The latter stages a resume image in DRAM at virtual 0xc0100000 and
  saves the first 64 DRAM bytes; the embedded resume code at file offset
  0x42ae0 restores these bytes from physical 0x40110400 and restores SRAM.
  Factory partial is a BSP-specific state, not equivalent by definition
  to modern s2idle. Neither standby current nor wake reliability can
  be inferred from disassembly.
- epdc_suspend (0x434 in epdc.ko) waits for pending LUT activity and may
  return -EBUSY. ELAN suspend (0x1f68) stops work and powers touch down
  except one state; resume resets it. The modern driver PM and physical
  frame acknowledgement already cover these essential invariants.

## Factory BT0 retained DRAM path

The actual boot0, not a generic vendor reference, contains this branch:

- 0x4b64: reads DRAMC SDR_DPCR (pad retention flag); when retained,
  avoids the DDR3 reset call, deasserting the controller reset instead.
- 0x4c40: tests the flag again, sets the super-standby flag at SRAM 0x51c8.
- 0x4c58–0x4ccc: reads AXP209 registers 0x0c, 0x0b, 0x0a, assembles
  the saved 20-bit ZQ calibration and writes DRAM ZQ control.
- 0x4cd4: clears pad hold, followed by DQS training (0x49b0); failure
  is checked. Host ports are configured and size derived from DCR.
- 0x818–0x82c: if super-standby flag is 1, arms watchdog then transfers
  control to physical 0x40100000 through the branch helper at 0x50f0.
  It bypasses normal BT1 loading. The vendor kernel stages the
  resume trampoline at that address, as corroborated above.

Factory uses PMIC scratch registers plus a fixed trampoline; pinned
Megi uses RTC GP0..3 for ZQ, physical cpu_resume, SUSP magic and DCR.
These are incompatible ABIs. Preserve Megi's ABI, not the vendor jump
address or scratch-register policy. Validate the exact x16 geometry
before accepting resume; require pad retention and matching metadata;
restore without DDR reset or destructive RAM sizing; preserve the
first 64 bytes overwritten by DQS training; keep early FEL priority
and a bounded failure/recovery policy. The original installed SPL
remains untouched.

## Adaptation in this repository

1. Idle policy now distinguishes unattended requests from explicit
   suspend. Unattended sleep requires confirmed battery discharge, no
   charging and no active/unknown non-loopback link. Both paths honor
   logind inhibitors and the physical qualification marker. Tests mock
   systemctl and sysfs, including rejected and accepted requests.
   Unlike the vendor process scan, this does not claim to detect every
   arbitrary CLI job; applications should use inhibitors.
2. Deep SPL validates the exact observed device/bus width and density,
   not merely capacity. The shared metadata predicate is used in the
   SPL and tested on host; the SPL cache key includes it. Source-built
   resume SPL is paired with the normal kernel by the installer.
3. Patches under patches/suspend correct the pinned Megi PMIC
   repeated-start/read (no false success on unexpected status),
   preserve the DRAM host-port enable mask and ARM caller registers
   during SRAM abort, and attempt to restore the PMIC wake flag and
   changed APB1 clock/gate on preparation failure or abort. The CPU PM
   notifier result is checked. These fixes are not a
   demonstrated hardware rollback; a failed PMIC rollback is logged.
4. The watchdog patch bounds DRAM command/pad polling, refuses an
   already active watchdog, and retains the rescue watchdog through
   kernel register restoration. If the PMIC acknowledges but power does
   not disappear, or DRAM cannot be safely restored, the SRAM path
   invalidates the RTC resume marker and waits for reset without
   returning through DRAM. This is a recovery policy, not a
   measured watchdog or rail-cut guarantee.
5. The normal kernel enables SUN5I_PM and ARM_CPU_SUSPEND. The same
   kernel and modules feed Debian and RAM recovery. The build executes
   the actual compiled SRAM object against a limited MMIO fault model
   on every run and checks I2C failures, abort register/port restoration,
   controller stalls and resume-marker invalidation. The installer
   binds the matching resume SPL to the recovery image. The model
   does not establish electrical power loss, DRAM retention or the
   hardware watchdog.

## Remaining qualification

The paired resume SPL needs cold boot/FEL and retention tests
with the normal kernel, actual DCR/ZQ, saved memory signatures,
PMIC rail measurements, watchdog recovery and power-key wake. Check
clock/reset sequencing against the actual board and prove that all
peripherals recover after power removal, including MMC, USB, Wi-Fi,
ELAN, E Ink and RTC. The suspend source bounds DRAM-controller polling and has a
watchdog escape, but the actual reset/rail-cut sequence and validation
of the precise resume address remain open. Keep unattended suspend disabled
until these are addressed and independent recovery is available.

For s2idle, use the existing qualification checklist. The kernel
wakeup-count contract and the final user-space-to-kernel transition
need a coordinated design, not an early write in an unrelated hook.
Timer wake is not established with the current DT. Do not add a fake
RTC IRQ or copy stock governor changes. Record power and wake source
measurements before choosing automatic policy or comparing the two
sleep depths.
