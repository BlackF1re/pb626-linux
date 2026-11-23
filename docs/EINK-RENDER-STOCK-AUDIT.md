# Stock PocketBook 626 Plus E-Ink vs Megi 7.2 — staged integration

## Basis and boundary

Hardware: PocketBook 626 Plus (ELAN eKTF2227, Samsung 8WPD3R eMMC, A13,
ED060XD4 758×1024 16 levels, TPS65185). Reference firmware archive provided
by the owner, version 5.20.1157, `boot/default.wbf` SHA-256
`bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f`.
The target Megi/Arnavion kernel is pinned at
`facc87117511221bb61410e3f92ad8579697f736`.

Do not copy vendor `epdc.ko` (Linux 3.0.8) into modern kernel or modify its
factory voltage or VCOM values. The full factory driver requires more
reverse engineering to reproduce advanced optical filters.

## Stage 1 — verified inventory

| Facility | Factory | Current Megi + userspace | Decision |
| --- | --- | --- | --- |
| Waveform decode | INIT, DU, GC16, GL16, A2, DU4 | all six already decoded in `pb626-epd.c` | expose two missing interactive modes |
| Temperature intervals | stock 14 | exact WBF 14 intervals | retain |
| DMA-driven frames / IRQ | stock EPDC LUT engine | **already available** in Megi's V4L2 vb2+DMA+TCON IRQ | no speculative kernel queue replacement |
| Region damage | factory rectangles | XDamage, 32×32 dirty tiles and per-pixel mask | retain, benchmark |
| Contrast/dither | NEON grayscale + diffusion variants | Rec.709 LUT + fixed Bayer/blue-noise | retain perceptual quality |
| Motion vs idle | factory multiple update APIs | DU then GL16, sparse GC16 after idle | retain |
| Ghosting | stock HQ/shadow LUT filters, not fully characterized | per-pixel transition count + same-level halo | no speculative port |
| Hardware timing | 85 scans/sec nominal | ~84.5 scans/sec measured | retain |
| Memory | stock memory-mapped eMMC SquashFS | full Alpine filesystem resides in RAM | avoid larger buffer allocations |

**Read the actual pinned kernel:** `drivers/video/fbdev/sun5i-eink.c`
has `eink_tcon0_irq_handler` switching buffers at frame boundaries,
`vb2_buffer_done`, an ordered workqueue, and safe `EINK_PAUSED` /
`EINK_STOPPING` states. It already queues physical frames back to back.
There is no basis to replace it with the vendor Linux 3.0.8 EPDC engine.

## Stage 2 — 14-temperature × 6-mode audit

Factory WBF: 85 scans/s nominal. The full matrix was decoded using the
stock RLE and checksum. These **physical transition capabilities** apply
across all 14 intervals, including cold and hot:

| Mode | 18–21 °C scans | 38–43 °C scans | Valid transitions |
| --- | ---: | ---: | --- |
| INIT | 145 | 103 | physical initialization |
| DU | 31 | 13 | old 0..15 to 0 or 15, except unchanged |
| GC16 | 59 | 40 | all 256, including same-level |
| GL16 | 59 | 40 | all except 15→15 (no pulses) |
| A2 | 15 | 10 | **only** 0→15, 15→0 |
| DU4 | 35 | 24 | any old 0..15 → **0, 5, 10, 15** except unchanged |

Modes already supported by the renderer's CLI remain valid. No mode may be
used to drive a transition absent from the *current temperature table*.

## Stage 3 — implementation on experiment branch

Opt-in fast-mode policy (`PB626_EPD_FAST_MODE` in the X11 bridge):

- `du` (default): existing behavior, preserves prior performance and
  quality.
- `a2`: select the factory A2 waveform only when **every** non-KEEP
  pixel is exactly 0→15 or 15→0. Check against the committed physical
  history (not just desired UI RGB); otherwise send the same frame using
  ordinary DU. Never convert an arbitrary grayscale source to A2.
- `du4`: deterministic 4-level (0,5,10,15) previews via stock DU4,
  with existing GL16 settling to full 16-level quality afterward.

Worker protocol is versioned `pb626-epd-shm-3` with explicit commands
for A2 and DU4. Worker caches all six stock modes. Unexpected unsupported
transition sets fall back: A2→DU, DU4→GL16, GL16→GC16, checked per
temperature. Full INIT/GC16 manual cleanup and sparse idle cleanup
are unchanged.

The stock waveform is *never edited*. Neither the A13 scanout timing nor
the TPS65185 power configuration is changed.

## Stage 3b — IDX8 experiment: rejected after pin-level regression test

The experimental 8-bit DEBE palette did not pass the full PIN32
equivalence test in workflow run 45205079484. The first 85 dot clocks
of a data row assert `G_CLK`, which the prototype omitted. The output
also differs by first-gate vs subsequent-gate `S_OE`. Thus the pin-level
signal has **four** independent control baselines (gate0/other ×
G_CLK on/off), not the two the prototype assumed.

For unrestricted source combinations, each baseline may require
`3^4=81` four-source states, i.e. up to **324 combinations**, already
exceeding the DEBE's 256-entry static palette, before fixed control
clocks. This is a capacity bound on an unrestricted static encoding,
not a proof about the observed unique combinations of any one frame.

Consequently `PB626_EPD_SCANOUT=idx8` is **not deployed**: it must
not silently skip control signals or be enabled for the owner's real
panel. The working `SUN5I_EINK_FMT_PIN32` scanout is retained;
`PB626_EPD_SCANOUT=pin32` may be specified explicitly. Attempts to
select any other value fail safely.

Any future indexed design would require a *proven* restricted palette
per waveform/update, switching to PIN32 where necessary, and complete
pin-level equality tests across all scan clocks, modes and temperatures.
Such work needs its own experiment; no RAM or speed gain is claimed.

## Stage 4 — verification and future work

CI/host assertions:

1. X11 bridge A2 eligibility rejects gray-source and accepts only 0↔15.
2. DU4 preview targets are exactly 0/5/10/15, and pixel history advances.
3. Existing cleanup, color profiles, dithering, sparse damage and full
   update regression tests continue to pass.
4. Check on-device behavior at both 18–21 °C and 38–43 °C with same
   content, exposure and panel temperature: black/white text scrolling,
   typing, grayscale, photo, ghosting, visible flash, total latency,
   PSS/CPU/OOM. Report A/B evidence, not inferred gains.

Pending opportunities **not claimed as complete**: async X11 capture
during hardware scan; target-quality GL16/GC16 auto-calibration;
optical characterization of vendor HQ/shadow filters; NEON CPU hot path
if profiling justifies; a complete kernel-level EPDC equivalent.
These require actual profiling/photography, and would be irresponsible
to enable blindly on the only working physical reader.

**Safety:** leave eMMC, SPI NOR, VCOM, factory WBF and voltage untouched;
test with FEL RAM and retain the original build for rollback.
