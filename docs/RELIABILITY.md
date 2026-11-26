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

## Next steps and hardware gates

- Verify normal and intentionally interrupted refreshes, service restarts,
  USB login, delayed input registration, missing WBF and temperature failures.
  Live input hotplug and uninterruptible kernel faults require further testing.
- Test bounded tmpfs and separate cgroup limits against real application usage;
  avoid arbitrary hard limits or disabling the OOM killer.
- Measure Wi-Fi power/runtime PM and module dependencies before unloading.
- RGB565, smaller XShm strips, packed levels/transitions, SIMD and shared
  framebuffer need correctness and latency comparisons; do not combine
  their theoretical savings as if measured. Retain current 24-bit X11.
- Do not free the DMA queue during ordinary use; suspend/charger-only UI,
  critical battery shutdown, pstore/ramoops and in-place updates need
  board qualification. Keep last verified rescue image.
