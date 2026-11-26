# Native reliability and memory policy

The scanout worker uses bounded command/ACK deadlines (45 s from send,
including overlapped INIT), and bounded reap with EOF, TERM and KILL.
If the worker cannot be reaped, do not create a replacement; the inherited
bridge lock and the video device flock prevent concurrent panel owners.
Recover from a failed operation with RESET, which uses factory INIT before
the next full frame. A stuck kernel ioctl requires operator recovery;
no automatic power cycling or unsafe reset. The ready marker is removed on
update failure. Temporary sensor read failures are retried before driving
the panel. An out-of-range temperature still prevents output. Indexed
allocation failure falls back to staged rendering without reducing the queue.

The full neutral template is now generated in each DMA buffer at allocation;
only two 256-word row patterns are retained for sparse updates. Host tests
compare those patterns with every row of the original scan template.
This removes about 0.89 MiB of always-touched worker storage, not DMA.
PIN32 timing, voltage, waveform, grayscale, protocol and eight-buffer
queue are unchanged. No framebuffer/depth changes.

Panel and keyboard are independently retried, while a dead WM or desktop
ends the session. Native OpenRC has a limited restart budget and USB login
is independent. ELAN registration is given a bounded startup window.
The renderer gets modest OOM preference; ordinary apps do not inherit it.
Run pb626-profile-memory as root before and after a workload. Record
PSS, MemAvailable, CMA, zram and PSI; PSS alone excludes kernel memory.

## Debian renderer resource isolation

The desktop service and the transient renderer scope are sibling units in
pb626.slice. systemd-run --scope (Debian systemd 257) retains the launcher
environment and execs the bridge in place; its child worker inherits the
same cgroup. BindsTo and After tie the scope lifetime to the desktop.
The scope has CPUWeight=200 (desktop default 100), MemoryLow=16M,
OOMPolicy=stop and a bounded stop timeout. The parent slice has the
same MemoryLow allocation so the soft reclaim preference propagates.
This is not a 16 MiB reservation, a guarantee against OOM, or a hard
limit on browsers. No system-wide OOM daemon is added. OOMScoreAdjust
and nice preference are retained only for the renderer.

Verify the scope exists and contains only bridge/worker processes;
record memory.current, memory.low, memory.events, pressure and CPU
weight with pb626-profile-memory while compiling, browsing, sleeping
and restarting. Confirm the old scope disappears before a new owner
acquires the panel. For diagnostic recovery, set PB626_RESOURCE_SCOPE=0
in the desktop service environment and restart; this restores the
previous same-service behavior. Alpine/FEL are unchanged.

## Device-driven desktop lifetime

Debian's desktop binds to dev-video0.device and orders after it. A udev
rule tags video0 for systemd and requests the desktop when it appears,
including delayed registration. The device job is bounded at 30 s:
missing E Ink must not block the independent USB rescue console forever.
The worker still verifies the sun5i-eink driver and format before output.
PID 1 creates/removes the existing runtime directory; no Debian loop
polls for video0 or manually deletes the service-owned directory.
The legacy Alpine/manual startup path keeps its original bounded wait.
ELAN readiness uses the weak dev-input-pb626_touch.device dependency
and a 5-second job timeout instead of a repeated sysfs scan in Debian.
Absence permits the existing pointer fallback. Manual/Alpine startup
keeps bounded discovery. Dynamic touch hotplug is not implemented.
The Debian rootfs builder runs its own systemd-analyze verify and
udevadm verify on installed units/rules before emitting an image.

## Critical battery confirmation

The ordinary 60-second fallback timer and power_supply uevents remain.
A first confirmed critical reading arms a nonpersistent one-shot systemd
timer for 12 seconds, not a continuously faster polling loop. A second
reading at least 10 seconds later and a final charger recheck are required
before requesting normal poweroff. Missing charger-online telemetry,
contradictory supply state or a recovered capacity clear the confirmation.
This intentionally fails closed on unverified telemetry; validate AXP209
status and shutdown margin on the actual battery. Host tests use fake
sysfs, uptime and a fake systemctl, never the host power manager.

## Next steps and hardware gates

- Verify normal and intentionally interrupted refreshes, service restarts,
  USB login, delayed input registration, missing WBF and temperature failures.
  Live input hotplug and uninterruptible kernel faults require further testing.
- Test bounded tmpfs and the renderer's soft cgroup preference against real
  application usage; avoid arbitrary hard limits or disabling the OOM killer.
- Measure Wi-Fi power/runtime PM and module dependencies before unloading.
- RGB565, smaller XShm strips, packed levels/transitions, SIMD and shared
  framebuffer need correctness and latency comparisons; do not combine
  their theoretical savings as if measured. Retain current 24-bit X11.
- Do not free the DMA queue during ordinary use; suspend/charger-only UI,
  critical battery shutdown, pstore/ramoops and in-place updates need
  board qualification. Keep last verified rescue image.

## Candidate: idle DMA queue reclamation

The worker supports a RELEASE_QUEUE command after STREAMOFF, unmaps all
buffers and issues VIDIOC_REQBUFS(count=0). The worker remains the sole
owner of the video device and retains the acknowledged packed panel
history. The next update lazily allocates the ordinary full queue and
rebuilds neutral templates; no INIT or waveform change is introduced
solely by freeing buffers. Potential reclaim is about 7.1 MiB of DMA/CMA,
not an increase in physical RAM. The bridge can release after 30 seconds
of settled inactivity or before acknowledged suspend, using its
existing deadline loop. No extra timer is armed when disabled.
This is opt-in only: create /etc/pb626/dma-release-qualified as root
after testing reallocation, repeated idle/wake cycles and severe memory
pressure on the physical board, then restart the desktop. Remove the
marker to restore the known persistent-queue behavior. Do not qualify
the experiment on QEMU alone. Record CmaFree, MemAvailable and refresh
latency before/after; a failing ioctl follows existing worker recovery.
