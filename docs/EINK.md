# E Ink hardware, waveform and renderer reference

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

## Verified inventory

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

## Factory waveform: 14 temperatures × 6 modes

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

## Current renderer

The installed Persistent Generic was built from the historically tested
worker and bridge (PR #13). Canonical sources in display/ now implement
that same startup architecture: early INIT in one worker before Xorg,
then first logical RESET sent as CLEAN after positive INIT acknowledgement.
The default fast preview is DU, followed by GL16; A2/DU4/auto remain
selectable subject to transition eligibility. Manual RESET is never
skipped. Shared frame protocol is pb626-epd-shm-4. The worker keeps the
committed history only after successful physical scanout. Native uses
indexed group rendering with PIN32 output, not a reduced-width bus.

The old IDX8 palette prototype was rejected: first 85 data clocks assert
G_CLK; first/subsequent gate S_OE differs. Four independent baselines
times up to 81 four-source combinations require up to 324 entries before
fixed clocks, exceeding a 256-entry unrestricted palette. The active
indexed group dictionary is a CPU rendering optimization, not IDX8
scanout. Never substitute a different waveform, VCOM or pin timing.

No claim that scanout ACK alone establishes optical quality. Stock
advanced HQ/shadow filters and full optical calibration remain unimplemented.
