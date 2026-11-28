# PB626 suspend/resume design and qualification

Scope: observed late ELAN/eMMC A13 board, pinned Megi kernel
facc87117511221bb61410e3f92ad8579697f736 and Debian/systemd. These are
software candidates, not evidence of successful physical sleep.

## Three mechanisms

* Working idle: scheduler idle/ARM WFI, tickless HZ=100, CPUFreq and
  independent device runtime PM. No freezing apps or interpreting screen
  inactivity as system inactivity. The A13 DT has no additional CPU
  idle states; generic ARM cpuidle deliberately falls back to arch idle
  when only WFI exists. Do not invent a deeper DT idle state.
* s2idle: systemd suspend -> Linux freezer and device PM -> idle CPUs.
  DRAM remains powered, no SPL execution. The AXP20x power key has
  existing IRQ-wake callbacks. The required pb626-sleep.service uses an
  AssertPathExists qualification gate (not a skippable Condition), including
  direct systemctl suspend; an inactive desktop also rejects preparation.
* deep: Megi SUN5I_PM is a PMIC-assisted SoC power cycle with retained
  DRAM, not a normal CPU idle state. The installed BT0-uncaged lacks
  a qualified resume-aware SPL, so SUN5I_PM remains disabled. A separate
  source-built deep candidate exists; see BT0-uncaged/RESUME.md.

## Factory evidence

Owner-supplied 5.20.1157 archive: boot/script.bin pm_para standby_mode=1;
pmu_para selects AXP209 on TWI0 0x34, IRQ 0. libhwconfig.so device_suspend
(0x5b38) selects partial or mem on platform 14. The matching BSP source
maps partial to normal standby and mem to super standby. The factory
partial state is not part of the modern Linux suspend ABI.
ektf2k_elan.ko elan_ktf2k_ts_suspend (0x1f68) cancels work and calls
SetTouchPower(0) except state 6; resume (0x1ec) calls SetTouchPower(1)
and ektf2k_reset. epdc.ko epdc_suspend (0x434) checks pending LUT work
and can return -EBUSY. The FEX describes multiple revisions; its
declared 512 MiB does not establish physical RAM beyond the observed
256 MiB. Do not copy raw factory PMIC or charger settings into Linux.

## Runtime and system device PM

The E Ink driver holds a runtime PM reference for the full VB2 stream,
including an empty/paused queue. STREAMOFF parks pins, tristates
outputs, flushes work and returns buffers. After 5s of inactivity
the runtime callback masks the TCON IRQ, disables VCOM, drive and
logic supplies in that order, asserts reset and gates clocks.
TPS65185 supplies their own VCOM and drive settling delays. Runtime
resume restores clocks, timing and safe parked registers; rails
remain off until STREAMON. System PM rejects active streaming and
uses pm_runtime_force_suspend / pm_runtime_force_resume. Rail errors
abort suspend; separate ownership flags preserve regulator counts.
No waveform or VCOM change. Logical frame history remains valid.
The one-shot renderer's V4L2 close attempts a synchronous runtime suspend
once the queue is released; an active stream's PM reference prevents an
unrelated close from powering it off. The platform shutdown callback also
reuses the synchronous parking sequence. Normal desktop streaming retains
the 5-second idle policy. The power-off service no longer sleeps for a
fixed six seconds. Confirm rail timing and shutdown on hardware.

ELAN eKTF2227 now disables IRQ, releases all contacts and powers down
its regulator before sleep. On resume it uses the same reset, hello
and resolution handshake as probe, then enables IRQ. Two bounded
attempts; failure is reported, not hidden behind an enabled IRQ.
Power button is the system wake source, not touchscreen.

The non-wakeup A10/A13 LRADC driver now masks its IRQ, stops
conversions and releases cached key state during suspend; resume
restores conversion/IRQ settings if the input is open. The existing
open/close regulator reference stays balanced (AVCC is shared).
The power key is an AXP20x IRQ wake source. GPIO keys, MMC, I2C,
USB host/MUSB, and PWM backlight already have subsystem PM paths.
The RTC node has no IRQ specified on this board: RTC alarm wake
is not established. Wi-Fi association, USB PHY/VBUS, SD/eMMC data
integrity and all input paths need physical qualification.
The system transaction switches off the frontlight and LED before
sleep, including when entering sleep from convenience lock. It
restores saved settings on resume and reports restoration errors.
Driver PM callbacks, not unload scripts or direct GPIO writes, own
hardware transitions.

## Deep sleep boot contract (blocking)

Kernel commit 4d8a701b7f3e2293e7557a99e597f8ad9d06dd37 introduces
pm-sun5i.c and sleep-sun5i.S. It records DRAM ZQ calibration,
physical cpu_resume address, SUSP magic and DRAM geometry in RTC
GP0..3, enters DRAM self-refresh, retains pads and uses AXP209 to
cut SoC rails. The SPL must detect both retention and magic BEFORE
cold DRAM initialization, recover DRAM nondestructively and jump to
cpu_resume. It must preserve cold boot, FEL and failed-resume recovery.
The exact dirty source tree of the installed lab SPL is still missing,
although the historical DRAM helper and board defconfig have been
recovered and match the independent source candidate. The candidate
implements the RTC/pad-retention handoff but is not qualified. Keep
CONFIG_SUN5I_PM disabled and do not substitute either candidate for the
working SPL.

## Qualification checklist

With a verified full backup and working FEL/serial recovery, test
PM_DEBUG and PM_SLEEP_DEBUG freezer/device stages first, then actual
s2idle (pm_test must be none). Record suspend_stats, wakeup_sources,
kernel messages, CPUFreq, IRQ deltas, regulator state, runtime_status,
power measurements and scan latency.

- reading idle while compilation or network transfer is active;
- button, timer, Settings and systemctl suspend; rejected/aborted
  sleep, immediate wake, held power button and repeated wake;
- rails off and correct retained E Ink image; correct first scan
  and restored saved backlight and LED state;
- touch contact held during suspend, touch coordinates after wake,
  GPIO/LRADC keys, power-button wake, eMMC integrity, external SD,
  RTC/time, USB gadget/charger, Wi-Fi reconnection and transfers;
- memory pressure, DMA reallocation, battery and charger telemetry;
- repeated cycles with no missed wake, leaks, filesystem errors or
  resume storms.

Only create /etc/pb626/suspend-qualified after the physical tests.
Deep sleep needs separate SPL/DRAM-retention qualification. CI and
QEMU cannot certify the PMIC or real device wake.

## Wi-Fi and USB runtime power management

In the pinned Arnavion kernel `facc87117511221bb61410e3f92ad8579697f736`,
`drivers/net/wireless/realtek/rtl8xxxu/core.c` registers a USB driver
without `.supports_autosuspend`, `.suspend`, `.resume` or `.reset_resume`.
It does not advertise mac80211 `SUPPORTS_PS`. Writing `auto` to the USB
power-control sysfs node cannot supply these missing driver operations.
The USB core unbinds interfaces lacking PM callbacks at system suspend
and rebinds them at resume. iwd may reconnect but this must be measured.
Do not force autosuspend, unbind the radio while browsing, or add dummy
callbacks. The stock RTL8188EU module has its own LPS/IPS and USB suspend
implementation; porting this requires real driver work and link tests.
The pinned MUSB core already implements runtime suspend/resume and a
500 ms autosuspend delay. Keep its native policy; do not override active
USB gadget or VBUS handling. Settings power requests now explicitly honor
logind sleep inhibitors. A display-idle timer is opt-in and cannot infer
whether a terminal job is important: use `systemd-inhibit --what=sleep
--mode=block <command>` for work that must not be interrupted. No automatic
suspend is enabled by default.

### Confirmed limits of the stock radio and boot inputs

The supplied archive contains rootfs/lib/modules/8188eu.ko, including
rtw_suspend (0x3e588), rtw_resume (0x3e7a0), rtw_suspend_common,
rtw_resume_common, LPS_Enter/Leave and ips_enter/leave. Module metadata
lists rtw_power_mgnt, rtw_ips_mode and rtw_low_power. Its symbol table
does not contain usb_autopm_get/put_interface or usb_enable_autosuspend;
the existence of LPS/IPS and system sleep entry points is not proof
that stock USB runtime autosuspend was enabled. Keep radio association
and USB rescue usable; do not force an unsupported PM state.

The archive contains boot.axf, bImage, script.bin and vendor modules,
but neither the exact private pb626-spl.bin input nor the source tree
that produced it. Public U-Boot v2026.07 dram_sun4i.c explicitly clears
SDR_DPCR and performs cold initialization, discarding retained data.
It cannot substitute for a resume-aware SPL. A new source-reproducible
SPL needs board-specific non-destructive training, resume handoff and
cold Menu FEL validation independently of this Debian userspace.

## Source-level review of the current sleep paths

The review covers the production Debian configuration and the separate
deep SPL candidate, against the pinned Megi kernel above. It does not
certify a physical sleep cycle.

| Mechanism | Production policy | Qualification |
| --- | --- | --- |
| CPU WFI / tickless idle | Enabled | No full-system sleep; measure idle power |
| E Ink runtime PM | Enabled, stream-scoped reference, delayed rail/clock parking | Rail sequence, error rollback and repeated scans need hardware |
| Convenience lock | Enabled by policy, no freezer or system PM | Optical/interaction check; not an authentication boundary |
| Suspend to idle | Built in, explicitly `mem` with `MemorySleepMode=s2idle`; gated by root marker | Hardware wake, aborted sleep, peripheral restoration not certified |
| Standby (shallow) | Not selected; no platform shallow state demonstrated | Not supported |
| Suspend to RAM (deep) | Disabled in resolved kernel config | Experimental separate SPL only; see blockers below |
| Hibernation / hybrid / suspend-then-hibernate | Disabled in kernel/systemd; zram is volatile | Not supported |

### s2idle transaction and failure boundaries

1. Settings, the bridge's short power-key policy and optional xidle
   call the validated admin helper, which requires the marker and honors
   logind inhibitors. Direct systemctl suspend also requires the
   preparation service. Direct writes to /sys/power/state bypass this
   userspace contract and are not a supported desktop suspend path.
2. The required oneshot runs before sleep.target and systemd-suspend.
   Requisite and AssertPathExists reject a stopped desktop or absent
   qualification marker. Its preparation client uses a bounded root-only
   Unix seqpacket request. No initial frame or failed input grab rejects
   preparation. The renderer's ACK follows every completed V4L2 phase
   and STREAMOFF, not merely a successful send. Optional DMA queue
   release is independent and still qualification-gated.
3. The kernel freezes tasks, invokes device PM, and enters s2idle.
   The pinned AXP20x PEK driver marks its device wake-capable, enables
   IRQ wake on both button edges and clears pending button interrupts
   in resume_noirq. IRQ wake return values in that driver are not checked;
   actual parent IRQ delivery and wakeup counts still have to be measured.
   The board's PCF8563 RTC has no IRQ in the DTS. Do not assume timed wake.
4. E Ink system suspend rejects active streaming and parks the hardware
   synchronously through runtime PM. ELAN releases touches, disables
   its IRQ and powers down; resume repeats the handshake before enabling
   IRQ. LRADC stops conversions, releases its cached key and restores
   the configuration for an open input device. MMC and mv64xxx I2C
   have force-suspend/resume callbacks in the pinned tree; their presence
   is not a storage or bus integrity test. rtl8xxxu lacks driver suspend,
   resume and autosuspend callbacks; reconnection is not guaranteed.
5. The oneshot's stop-post restores the desktop on both resume and failed
   preparation. A new physical X11 frame and restored indicators precede
   the resume ACK. The bridge now retains a separate RESUMING phase
   until that ACK, draining queued power-key edges at both boundaries;
   a release from a held wake key cannot immediately request sleep again.
   A failed scan or indicator restore is reported, not acknowledged as
   success. Desktop teardown also attempts indicator restoration.

Host tests cover frame math, V4L2/worker protocol logic, power-key edge
parsing, policy and the static service contract. Target Debian validates
installed systemd units. None executes the kernel freezer and all device
PM callbacks on this board. The test matrix must include successful and
aborted transactions, not just successful wake.

### Deep kernel/SPL review: additional blockers

The pinned `arch/arm/mach-sunxi/pm-sun5i.c` and
`sleep-sun5i.S` implement a real platform suspend-to-RAM proposal:
the kernel saves CCU/INTC/PIO/timer/SRAM state and the first 64 bytes
of DRAM, publishes RTC GP0..3, moves the last operation to SRAM,
and requests an AXP209 rail cut. The candidate SPL consumes the magic,
validates alignment/range and the saved single-rank 256 MiB DDR3
geometry, excludes FEL, checks retained pads, restores the controller,
trains DQS and jumps to the saved physical resume address. Successful
kernel return stops the SPL watchdog and restores saved registers.

The following are unresolved correctness issues, not merely performance
tuning:

- `sun5i_axp_prepare()` modifies CCU/APB1/TWI and the PMIC VOFF wake
  flag before the final power cut. `sun5i_pm_enter()` returns directly
  on preparation failure and only restores the saved CCU/peripheral
  state after a successful cpu_suspend return. Abort and partial-PMIC
  failure need explicit rollback, including the wake flag and original
  clock/IRQ state. The polled PMIC read path also treats any unexpected
  I2C status at the final read as success; error handling needs review.
- The SRAM abort path enables all 31 DRAM host ports rather than
  restoring their original enable mask. Pad and DRAM-command waits are
  unbounded; a hung controller or an ACKed PMIC write without actual
  rail cut has no demonstrated recovery path. The SPL watchdog is
  armed only on the wake-side candidate, not throughout kernel entry.
- The SPL validates a broad aligned physical resume range, not the exact
  installed kernel's resume address or an authenticated retained image.
  It consumes the RTC magic before the retained-pad check. Unknown
  retention, stale metadata, FEL intervention, power loss and a
  watchdog retry must have a defined cold-recovery policy; the current
  range/geometry checks alone do not prove a safe handoff.
- Verify the actual 256 MiB board DDR3 geometry, pad retention, DRAM
  rail wiring, CPU/DRAM clocks, DQS training and preserved RAM on physical
  hardware. The deep kernel reprograms several register files directly,
  so driver callbacks which suffice for s2idle may not suffice after
  every SoC register has been lost.
- The Cortex-A8 model executes real Menu/FEL, raw-sector and LED code
  but stops on unmodelled controllers. It does not execute an entire
  retained-DRAM transition. A compiled deep SPL and a successful
  differential cold-path test therefore do not establish deep resume.

Do not make the deep candidate an installable default, enable
CONFIG_SUN5I_PM in the production kernel, or change the s2idle policy
until these issues and the independent recovery prerequisites have
been addressed. Separate lab artifacts, an exact paired kernel/SPL,
and a repeatable physical qualification report are required.
