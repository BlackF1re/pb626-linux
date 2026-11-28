# Suspend-to-RAM bootloader contract

The normal firmware contains a source-built resume-aware SPL paired with
the Megi A13 kernel and matching modules. The historical hash-qualified
BT0 remains a cold-path comparison and recovery reference, not a
substitute for the resume SPL. Independent SD recovery did not work on
the observed late ELAN/eMMC unit.

The matching kernel saves RTC GP0 (DRAM ZQ), GP1 (physical cpu_resume),
GP2 (SUSP magic) and GP3 (DCR), enters DRAM self-refresh, retains pads
and asks AXP209 to cut SoC rails. The SPL must not run cold DRAM
initialization on a retained image.

## Implementation and constraints

- The early Menu/LRADC hook and FEL dispatch take priority over resume.
- Retained pads, RTC magic and the exact observed 256 MiB single-rank
  x16 DDR3 geometry are required; the saved physical address must be
  aligned and in the expected range.
- Restore controller state without DDR reset or RAM sizing; run DQS
  training, whose first 64 bytes are saved by Linux, then jump to
  cpu_resume with MMU and D-cache off. The rescue watchdog protects
  the handoff; the kernel restores saved registers.
- Cold boot, raw MMC2 uImage loading and FEL must remain intact.

The pinned historical Megi U-Boot configuration and board DRAM helper
are documented in SOURCE.md. The current source preparation is in
prepare-source-resume.py. The independent bootloader model exercises
Menu/FEL, raw sector and LED behavior against the reference binary.
The actual SRAM suspend routine is tested under a limited MMIO model.
Neither model can establish physical retention or the wake rail sequence.

## Hardware acceptance

Verify cold boot, repeated Menu/FEL recovery, wake by power button,
retained memory signatures, eMMC integrity and repeated wake under
memory pressure. Check loss of power, stale resume metadata, watchdog
recovery and peripheral restoration. Use the exact same-run kernel/SPL
pair; do not mix legacy bootloaders with the suspend-enabled firmware.
Only set the systemd suspend qualification marker after physical tests.
