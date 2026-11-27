# PB626 terminal diagnostics

Installed by pb626-runtime as /usr/sbin/pb626-diagnostics (POSIX shell,
no Python runtime required by this tool; optional native pb626-diag-clock helper is shipped with it). On a running older image copy
this file via SCP and invoke sh ./pb626-diagnostics; the inventory also
works without systemd but the active panel and suspend tests require the
managed Debian image. Root is needed for full PSS and device access.

    sudo pb626-diagnostics --output baseline.txt --interval 60 --bench

Without --output, prints to stdout. Reports are private (0600) and are
never overwritten. The report includes boot relative to kernel entry,
unit timings, renderer journal, CPU/IRQ counters, PSS/CMA/zram/PSI,
battery samples, PMIC, regulators, input, RTC, LED/backlight, MMC, USB,
V4L2, Wi-Fi and power/suspend counters. The before/after snapshots
support comparison; raw units are retained. Missing drivers/tools are
not passed tests. No daemon is installed.

Optional active tests:

    sudo pb626-diagnostics --output input.txt --input /dev/input/event0 20
    sudo pb626-diagnostics --output network.txt --ping 192.168.1.1
    sudo pb626-diagnostics --output sleep.txt --suspend
    sudo pb626-diagnostics --output sleep-trace.txt --trace-suspend

Input records event values: use only test keys and do not type passwords.
Suspend honors systemd policy, requires an already-qualified s2idle and
pm_test none, requires manual wake, and may disconnect SSH. A new kernel
success counter is required for a confirmed suspend. It reports elapsed
time including sleep and journal timestamps, not power-button latency.

To benchmark all six panel modes, use a USB console, not the graphical
terminal. Stop the desktop manually first:

    sudo systemctl stop pb626-desktop.service
    sudo pb626-diagnostics --output panel.txt --panel 3
    sudo systemctl start pb626-desktop.service

The real renderer owns the display via flock. It exercises INIT, DU,
A2, DU4, GL16 and GC16 with valid transitions and prints actual scan
count, render/index/preload/stream/IRQ timings, total time and ACK
evidence. A failed or missing scan ACK stops the panel sequence. This
does not measure optical response or ghosting. The one-shot process
also has controller startup and shutdown overhead. No voltage, WBF,
DMA queue or qualification marker is changed. Use the existing
hardware qualification protocol for optical comparisons.

## Coverage requiring physical observation

- Cold boot duration from power key, independent FEL and USB host
  enumeration: stopwatch/host logs, repeated cold cycles.
- Deep sleep, battery current under sleep, charger-only cold start,
  disconnect/reconnect and display restoration: external meter and
  operator; never auto-enable unqualified functionality.
- Touch geometry, button actions, LED/frontlight and optical quality:
  exercise on device. Mere device registration is not a functional pass.
- Network throughput/reconnection, SD read/write and USB backup/restore:
  test controlled peers/disposable media with the existing recovery
  procedure. The default benchmark reads 32 MiB from each whole MMC
  device without writing; it does not benchmark random/write I/O.
- GPU/Lima is still opt-in, and there is no independent physical
  test of every hardware register. See docs/HARDWARE-QUALIFICATION.md.

Host CI runs the pure binary PGM pattern tests and CLI parsing.

## Timing accuracy

The shell uses pb626-diag-clock, a small on-demand C executable, for
high-resolution CLOCK_MONOTONIC_RAW and CLOCK_BOOTTIME timing of actual
child processes, reporting nanoseconds, CPU user/system microseconds
and max RSS. The report records clock_getres and the active kernel
clocksource; nanosecond representation is not nanosecond physical
accuracy. Cold one-shot panel timing includes process startup; the
existing renderer separately reports prepare/render/scanout/IRQ timing
in microseconds. Missing helper explicitly falls back to the 10 ms
formatted /proc/uptime. The memory benchmark touches 8 MiB and measures
64 MiB payload copy and fill; it skips below 24 MiB MemAvailable.
CPU SHA256 and direct MMC read tests report the raw timing too.

For software end-to-end X11 measurements, enable PB626_EPD_PROFILE=1
for the managed desktop temporarily (systemd runtime override), then
exercise a fixed workload and capture the journal. This adds overhead
and is not enabled permanently. Compare XDamage capture, quantization,
submission and ACK against the one-shot renderer's waveform timing.
Physical touch-to-pigment latency still needs external equipment.

--trace-suspend creates its own tracefs instance, enables the
power:suspend_resume and power:device_pm_callback_* events when
available, records the clock and overflow statistics, and removes the
instance afterwards. It does not touch existing/global trace buffers,
enable deep sleep or mount tracefs automatically. Without the appropriate
kernel trace configuration or access, the report labels trace unavailable.
The difference of BOOTTIME and MONOTONIC_RAW deltas estimates suspended
time, subject to clock calibration and user-space polling delay; use
kernel trace events for callback timing and external timing for true
power-off/wake latency.

The verified-BT0 comparison and all candidate tests remain separate
from this runtime tool. A diagnostic reading or synthetic PGM test does
not qualify an untested physical driver or flash a candidate.
