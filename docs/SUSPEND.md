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
  a resume-aware SPL, so SUN5I_PM remains disabled.

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
The exact source/config of the installed private SPL base has not
been recovered; the stock filesystem archive does not supply it.
Keep CONFIG_SUN5I_PM disabled. Do not flash a guessed SPL.

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
