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
| Memory | stock memory-mapped eMMC SquashFS | RAM desktop uses a bounded initramfs; native root is on eMMC | avoid larger buffer allocations |

**Kernel scanout:** `drivers/video/fbdev/sun5i-eink.c`
has `eink_tcon0_irq_handler` switching buffers at frame boundaries,
`vb2_buffer_done`, an ordered workqueue, and safe `EINK_PAUSED` /
`EINK_STOPPING` states. It already queues physical frames back to back.
The port reuses this queue instead of replacing it with the vendor Linux 3.0.8 EPDC engine.

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

The native renderer uses the physically tested Persistent Generic architecture (PR #13): early INIT in one worker before Xorg,
then first logical RESET sent as CLEAN after positive INIT acknowledgement.
The default fast preview is DU, followed by GL16; A2/DU4/auto remain
selectable subject to transition eligibility. Manual RESET is never
skipped. Shared frame protocol is pb626-epd-shm-4. The worker keeps the
committed history only after successful physical scanout. Native uses
indexed group rendering with PIN32 output, not a reduced-width bus.

PIN32 is required: the first 85 data clocks assert G_CLK and first/subsequent gate S_OE differs. Four independent baselines × 81 four-source combinations can require 324 palette entries before fixed clocks, exceeding IDX8's 256. Indexed group rendering optimizes CPU work, not bus width. Never substitute waveform, VCOM or pin timing.

### Application-level high contrast

Keep Xorg color visuals and all 16 physical levels by default. The optional
`mono` profile, selectable in Settings, thresholds the entire X11 image
at luminance 128, disables dithering and contrast analysis, and emits only
black and white. Use it for terminal work or text-heavy UI; switch back to
`balanced` or `photo` for pictures and antialiased content. Sleep and
shutdown images are composed separately and retain grayscale. Settings
also exposes `du`, `auto`, `a2`, and `du4` fast waveform policies. The
default remains DU; `auto` selects A2 only for compatible binary transitions
when the temperature-specific waveform is shorter, otherwise uses DU.
Neither this selector nor the mono profile requires application changes. Instead, publish neutral X11
resource defaults using xrdb before launching desktop clients
(`/etc/X11/pb626.Xresources`), including XTerm, NEdit and XCalc. The
existing Matchbox theme, keyboard patch, `mc -b` and `htop -C` remain.
Shell defaults `NO_COLOR=1` and `CLICOLOR=0` are advisory.

GTK2 gets neutral RC defaults; GTK3/4 request their HighContrast theme
and disable animations by default if installed later. No new GTK or Qt
runtime is bundled for this purpose. User overrides, custom widgets,
hard-coded colors and icons may ignore these defaults; configure such
applications individually. Do not recolor book content or photographs.
Qt does not have a universal monochrome setting in this Matchbox session;
select a verified monochrome palette when adding a Qt application.
The new settings require visual acceptance testing on the RAM desktop.

No claim that scanout ACK alone establishes optical quality. The stock
HQ/Shadow mechanisms have now been identified at the transition-mask
level; their opt-in adaptations below are not a full factory driver port.

### Optional white halo filters (experimental)

Evidence: factory epdc.ko SHA-256
9e1c18a44cd79679ad776213e38b734d52305dd905cc81e866bfb35fae8556d2.
The unstripped ARM ELF uses two interleaved byte planes in blocks of
eight pixels. enqueue_ur_neon (0x3d24) compares the old high nibble of
the transition plane with the new framebuffer high nibble; on enqueue
it stores the old level in the low nibble and target in the high nibble,
and writes the active LUT selector into the other plane. The scan
routine at 0x3c4c masks each waveform lookup by equality of that selector
to the current LUT number. Zeroing the selector therefore suppresses
the selected update rather than changing the stored image.

HQ (0x47e8) combines horizontal neighbour bytes with vertical neighbour
bytes; VSLI #4 takes their low nibbles into the test for FF. It clears
the selector for white-to-white pixels surrounded by old white.
Shadow (0x48b8) ANDs the transition plane against the table at 0x496c,
then clears the selector where the result equals FF. Four stages
alternate which row and which byte parity are kept; the alternating
mask shifts by one byte per eight source pixels and per row pair.
The stock update call site selects HQ or Shadow, not both.

The bridge's candidate adapts these rules only to **optional same-level
white halos** of its existing local GC16 cleanup. Pixels whose fast
transition count reached the mandatory threshold are always scrubbed.
Changed pixels, INIT, RESET, SETTLE, sleep and the power-off image are
unaffected. Nonwhite halo behavior is unchanged. HQ conservatively
keeps panel-border pixels; Shadow anchors the pattern to physical
gate/source coordinates rather than the stock rectangle origin and
advances only after ACK. These are deliberate differences from the
factory multi-LUT engine, whose scheduling and overlapping updates
have not been replicated.

Default: no filter. To opt into a measured candidate after qualification,
create /etc/pb626/halo-filter-qualified and set
PB626_EPD_HALO_FILTER=hq or shadow in a desktop service drop-in,
then restart the desktop. Remove the marker or set none to revert.
Compare residual edge shadows and white reflectance after repeated
typing, scrolling and manual cleanup; never qualify from scanout ACK
or host tests alone. Host tests prove each white pixel belongs to one
of four retained phases and mandatory scrub cannot be suppressed.

### Bounded grayscale starvation

An incomplete fast preview keeps its pending age even when other pixels
are successfully updated. After 850 ms of unresolved changes, the next
preview candidate becomes SETTLE (GL16, with the existing GC16 fallback).
A fully resolved binary frame clears that age, so continuous binary
typing does not itself force periodic grayscale updates. The deadline is
a scheduling bound, not a physical latency guarantee: capture and scanout
take time. This deliberately trades some motion responsiveness for eventual
gray accuracy in mixed-content animation. No changes to waveform tables,
transition eligibility, panel timing or the ghosting counters.

### Packed waveform temperature cache

Keep the original WBF two-bit transition signals in the six decoded mode
caches. Expand only the active update plan before rendering. This removes
301,056 bytes of fixed cache allocation (294 KiB) and the 16 KiB decode
scratch array, without changing the per-pixel PIN32 render loop, waveform
eligibility, repeat merging, temperature selection or the shared protocol.
The host regression checks all 256 transition indices, active filtering and
phase merging. Actual RSS savings depend on how many waveform pages were
resident; compare PSS and update timings on hardware.

### NEON and binary keyboard

The ARMv7 bridge builds with NEON for exact four-neighbour L1 contrast.
RGB565 binary blocks and neutral RGBX blocks (when the gray tone table
is the identity) also use eight-pixel SIMD conversion. Mixed colors,
nonidentity tone curves and short tails retain the scalar reference.
Regression tests compare both paths on unaligned partial rows and all
profiles; throughput still needs Cortex-A8 measurements.
Scalar tails and reference tests preserve all gray profiles and dither.
The keyboard uses black backgrounds, white non-antialiased labels and a
small white pressed outline. Existing DU and per-pixel cleanup apply to
binary changes without a separate keyboard renderer. Benchmark Cortex-A8
before claiming a speedup; the waveform and cleanup policy are unchanged.
