# Deep-resume compatibility contract (not an implementation)

The currently qualified BT0-uncaged reconstruction and its exact SHA-256
remain unchanged. A FEL failure cannot currently be recovered independently
via SD on the observed late ELAN/eMMC unit. Never replace the installed SPL
with an unqualified resume experiment. CONFIG_SUN5I_PM remains disabled.

## Inputs needed for a real change

- The exact original 24 KiB lab pb626-spl.bin identified in README.md, or
  the matching U-Boot revision, defconfig, source changes and toolchain.
- Ideally the original private first 68 MiB dump (factory BT0/BT1, with
  private data kept local). The provided stock filesystem archive contains
  boot.axf and Linux images but neither the lab SPL nor raw boot0/boot1.
- Pinned Megi kernel implementation of pm-sun5i.c; it describes RTC GP0
  (ZQ calibration), GP1 (physical cpu_resume), GP2 (SUSP magic),
  GP3 (saved DCR), and the DRAM pad-hold indication.

A retained DRAM resume is not the same as cold DRAM initialization. Generic
U-Boot cold initialization can discard retained data. A correct implementation
must reproduce the matching board-specific clock/DRAM resume sequence without
overwriting the image, stack, or resume vector in DRAM. Do not guess addresses
or insert a generic cold-init sequence into the qualified binary.

## Required behavior and acceptance

1. The existing early Menu/LRADC hook and FEL path retain priority, including
   a return through the FEL thunk. A resume request may not override Menu.
2. A no-resume cold start must remain identical in behavior, including MMC2
   and raw uImage loading. USB insertion alone is not a resume request.
3. Resume may be attempted only when both the RTC contract and the DRAM
   retention indication match. Validate the physical resume address and
   alignment against the matching kernel/DRAM layout before branching.
4. Unknown or contradictory retention state must not be treated as a valid
   retained image. Design and validate an explicit recovery strategy before
   enabling the new path. Avoid a warm-reset loop or stale resume marker.
5. Test FEL in SRAM before any flash write, then cold start, repeated Menu
   FEL, button and charger cold starts, warm reset, suspend/resume under
   memory pressure, and repeated resume cycles with verified memory contents.
   Exercise corrupted/stale resume metadata and loss of power during sleep.
6. A successful host model or assembly is not evidence that DRAM survived.
   Qualify the kernel and SPL together on hardware, with a full verified
   factory backup and a proven independent recovery route.

This document deliberately does not add a selectable resume binary or relax
the exact-hash gate in build.py. The current working idle and s2idle paths
are independent of this missing SPL resume support.

## Source-level retained-DRAM candidate

The historical Megi U-Boot source is now recoverable from the repository's
own prior build recipe. See SOURCE.md. The separate prepare-source-resume.py
modifies the pinned A13 DRAM helper before compilation. It consumes the
RTC SUSP magic, validates address/alignment and 256 MiB single-rank DDR3
geometry, requires retained pads, restores DCR/ZQ, avoids DDR3 RESET
and RAM sizing, exits self-refresh using the vendor sequence, runs the
DQS training whose first 64 bytes Linux saves, and jumps to cpu_resume
with MMU and D-cache off. It arms a rescue watchdog. The early Menu
hook remains first; eGON.FEL never resumes a retained image. This is
a cross-source experimental implementation, not verified A13 resume.
The vendor sequence was reviewed against hno/allwinner-boot
boot0/drv/init_dram/dram_init.c and the pinned kernel's sleep-sun5i.S.
Neither this SPL nor the matching deep-capable kernel is enabled by
default. A failed retention test or watchdog reset can lose unsaved
data; do not flash this candidate without independent recovery.
