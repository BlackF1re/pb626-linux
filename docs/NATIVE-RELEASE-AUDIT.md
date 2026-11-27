# Native release audit and qualification gates

This is a source-level review, not a hardware acceptance certificate. Target:
the verified PocketBook 626 A13/256 MiB variant, its original calibration and
waveform, and the pinned Megi Linux revision. Keep a verified recovery image
and the known working BT0 before testing any candidate.

## Power and sleep

- Preserve regulator ownership, shared AVCC, eMMC supply and validated CPU OPPs.
- E-Ink must park and complete STREAMOFF before sleep. Turn VCOM off before
  high-voltage rails and logic, retain the TPS65185 discharge delays; restore
  registers successfully before enabling panel rails. Failed probe must free
  IRQ before destroying the workqueue. Never shorten waveform or rail delays.
- s2idle: required renderer preparation, input quiescence, driver PM, and
  resume restoration. The qualification marker is not a substitute for tests.
- Deep sleep: CONFIG_SUN5I_PM remains disabled by default. A matched SPL is
  needed to restore retained DRAM. The pinned sleep-sun5i.S contains unbounded
  DRAM command/pad waits and assumes the PMIC cuts SoC power after acknowledgement.
  The abort path needs separate validation. Retain watchdog and independent
  FEL recovery; do not treat successful host tests as proof of retained DRAM.
- Wi-Fi: do not force runtime USB suspend while associated. The pinned rtl8xxxu
  lacks the necessary callbacks. Check disconnect/reassociation after system
  sleep. RTC wake is not established on the current DT.
- Charge-only UI and external SD remain opt-in pending physical qualification.

## UI and renderer

- The settings UI has scrollable tabs and bounded user-space command requests.
  Power-button input ignores incomplete events after SYN_DROPPED.
- Render completion means driver scan completion, not measured optical response.
  First-frame acknowledgement is logged even without full profiling.
- Keep the existing calibrated waveform, VCOM, temperature-dependent mode
  selection, eight scan buffers, conservative fallback and cleanup.
- Shared DDX, optional halo filters, DMA release and Lima require physical A/B
  qualification; avoid forcing aggressive changes solely to reduce RAM.
- Keep the planned SPL LED sequences separate from release qualification:
  Morse generation is unit-tested, but hardware error handlers and
  nonblocking normal-start signalling are not integrated yet.

## Acceptance sequence

1. Build all artifacts and verify the matched manifests and kernel ABI.
2. Verify recovery independently of the native root filesystem and candidate
   SPL. Keep a copy of the known working loader and original calibration.
3. Cold boots, shutdown images, reboot, buttons, touch, brightness range,
   charging/unplugging and low-battery handling.
4. Repeated s2idle wake cycles with and without Wi-Fi and USB; compare
   power-supply, regulator, clock and runtime PM state and verify filesystem
   integrity. Include aborted suspend and active transfers.
5. All six panel modes, black/white and grayscale transitions, full and partial
   updates, keyboard/scrolling, worker restart and memory pressure. Compare
   scan timings and visually check residual images.
6. Deep resume, SD, Lima and optional rendering optimizations are independent
   experiments. Do not change their defaults until the relevant tests pass.

Record baseline and post-change diagnostics on the actual device at matching
temperature, battery state and workload. A successful CI run only qualifies
the exercised host and build checks.
