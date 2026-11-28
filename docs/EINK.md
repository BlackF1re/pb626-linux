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
default remains DU. `auto` chooses DU4 when every changed target is
exactly one of 0, 5, 10, 15 and at least one is gray. Otherwise it uses
the DU preview, with A2 only for compatible binary transitions when the
temperature-specific waveform is shorter. The worker still validates the
actual WBF and falls back to GL16/GC16 for unsupported DU4 transitions.
Unchanged gray pixels in dirty tiles are never quantized by DU4. Neither
this selector nor the mono profile requires application changes. The
session also publishes neutral X11
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

### Experimental shared-framebuffer DDX

Trixie ships Dummy 0.4.0 (source package version 1:0.4.0-1). The native
build fetches that signed Debian source, applies
display/xorg-dummy-pb626-shared.patch without fuzzy matching and compiles
against the target Xorg development headers. It installs the private
dummy_drv.so under /usr/lib/pb626/xorg/drivers, leaving Debian's normal
module untouched. Source licenses are retained in the runtime package.
The existing Xorg software framebuffer is backed by a root-only shared
file in the service RuntimeDirectory; no additional screen-sized buffer.
The file is published atomically after ScreenInit, never truncated in
place, and geometry/masks are updated on RandR resize. The bridge opens
it read-only and verifies file ownership, size, ABI, geometry, bounds,
color masks and depth. It grabs the X server only while processing a
capture strip, not during waveform calculation or physical scanout.
Invalid mappings fall back to XGetImage, and ordinary mode still uses
MIT-SHM. The private module is not selected by default.

Only the native Debian managed service can select it, via a root-owned
/etc/pb626/ddx-shared-qualified marker. Removing the marker and restarting
returns to the unmodified driver. A failed candidate must not be treated
as proof that a different board's Xorg ABI is compatible. Host Xvfb tests
exercise the bridge using a synthetic shared pixmap derived from XGetImage,
with 16- and 24-bit depths, partial regions and nonzero offsets. This is
not yet an actual private-module Xorg integration test. Before enabling
by default, compare full and partial frames (including RandR, cursor,
window exposure, fonts and lock/resume) with XGetImage on the real Xorg
server. Measure PSS, capture/quantization latency, input delay during the
server grab, and behavior on server restart. The mapped path removes the
server-to-SHM copy and the ordinary SHM strip allocation when the mapping
is present; X server grab duration can offset that benefit. No claim of
speedup or physical validation is made.

### Exact-first interactive scheduling

A binary DU preview followed by GL16 can show an intermediate black or
white approximation that does not exist in the target image. At 18–21 C
this costs 31 + 59 scans (about 1.06 s), before capture/quiet time. The
bridge now uses a fast update only if every changed pixel in that frame
reaches its requested logical level with the selected preview. Otherwise
it discards the unsubmitted IPC preparation and sends one exact SETTLE
(GL16, existing GC16 fallback). Exact DU, A2 and DU4 remain available;
manual RESET, local GC16 scrub, sleep, waveform and VCOM are unchanged.
For workloads prioritizing approximate animation, set
`PB626_EPD_APPROX_PREVIEW=1` in the desktop service environment and restart.
This restores the previous preview scheduling (including the 850 ms bound).
The exact-first policy avoids intentional intermediate levels, not the
intrinsic optical flash of a factory waveform; verify text entry, window
open/close and images on hardware. Compare logged mode, ACK and optical
latency at equal temperature. Host tests exhaust all source/target levels
and check mixed-tile fallback and legacy approximation.

### Grayscale ghosting budget

GL16 is not a substitute for a mandatory same-level GC16 scrub. Count
acknowledged changed GL16 pixels in the existing saturated per-pixel
budget, just like DU/A2/DU4, without extra memory. This preserves bounded
cleanup when exact-first scheduling bypasses fast preview entirely. The
counter remains conservative: approximate mode can count both preview
and settle, and no optical equivalence of those waveforms is assumed.
The threshold, halo radius, optional masks and idle delays are unchanged.
Only an ACK consumes the budget or clears a scrub. Host regressions cover
repeated gray-only changes, saturation and successful local cleanup.

### Row-wise physical coordinate mapping

Capture now resolves rotation once per output row and advances native
panel coordinates by a unit step per pixel. Quantization and dirty-tile
marking reuse those coordinates instead of converting an index back to
x/y (division and remainder by 758) in the pixel loop. The regression
compares every panel coordinate in all four rotations against panel_index,
including partial row starts. The existing Xvfb full/partial comparison
continues to verify pixel output. No changes to dither, panel orientation
or capture geometry; target timing still requires measurement.

### Bounded XDamage coalescing

On the first normal XDamage notification after a completed capture, wait
up to a 24 ms coalescing window before reading the root. NonEmpty events
are not a per-paint clock, so this deadline is not extended by subsequent
notifications. If another damage notification arrives while reading the
strips, defer the unsubmitted frame for at most one recapture. Retain
all accumulated dirty tiles; a second capture must make progress even
under continuous animation. Boot, manual reset and lock/resume bypass
this policy. This reduces the chance of scanning a transient window or
partially painted widget. It does not change waveforms or cleanup.
The window adds latency to an isolated update, while potentially avoiding
hundreds of milliseconds of physical scanout for transient content.

Exact-first DU also drives near-endpoint transitions (for example 1→0
and 14→15) directly. The former approximation dead band is unnecessary
for a binary target and would otherwise force a slower GL16 fallback.
A2 eligibility still excludes nonbinary old levels; explicit legacy
approximation retains its original dead band.

### Combine already-due local cleaning with a settle

When both a grayscale settle and the existing idle cleanup deadline are
due, prepare one sparse GC16 frame covering the dirty pixels and due
same-level scrub pixels/halo instead of two sequential scans. The bridge
logs the local command S but sends the existing CLEAN wire command, so
no worker protocol changes are needed. Changed pixels in this GC16
frame reset their ghosting budget only after ACK. Never advance the
cleanup deadline, enlarge the halo, or combine with a pending capture;
large cleanup retains its five-second delay. The optical appearance of
GC16 still needs physical comparison; the factory sequence is unchanged.

### Sparse waveform planning

Collect the active transition indices once per update. For up to 64 of
256 possible transitions, expand only those entries from each packed
waveform phase into the existing zeroed LUT. Dense images and INIT retain
the full expansion path. Phase count, repeat merging, active mask and
all voltage signals remain byte-identical; no neutral scans are dropped.
Host regression covers dense, threshold-sized and single-transition
masks, including index 255. This reduces CPU work in sparse updates
without adding resident storage; measure actual preparation latency.

### Experimental simultaneous transition waveforms

The PIN32 worker already emits a per-transition signal in every scan.
For ordinary exact SETTLE or DU4 with known history, the candidate selects the
shortest eligible waveform for each old/new transition: DU for binary
targets, A2 for binary endpoints when selected by the fast policy,
DU4 for 5/10 when selected, GL16 otherwise, and GC16 only for a missing
GL16 transition. It checks the decoded current-temperature table.
Every chosen sequence starts on scan zero, retains all factory signals
in order, and emits neutral signals after completion until the longest
sequence ends. No extra full-screen buffer, protocol change or new
voltage/timing is needed. Same-level scrubs, INIT, RESET and sleep are
never mixed. ACK and ghosting accounting remain unchanged.

Mixed electrical sequences are not yet optically qualified: common panel
behavior, edge crosstalk, charge balance and temperature dependence must
be checked on the actual panel. The worker requires both the root-owned
/etc/pb626/mixed-waveform-qualified marker and PB626_EPD_MIXED=1 in the
service environment; without both, the existing exact update is used.
Approximate preview disables mixed planning even with the marker present.
For controlled lab qualification only, use a reversible service drop-in
and remove the marker if residual images or edge artifacts increase.
Compare identical black/white, gray and mixed charts over repeated
updates and temperatures; log selected counts and total scans. Host
regression verifies the full expanded signal sequence for four mixed
transition classes, neutral tails, disabled A2 and invalid/scrub rejection.

### Single-pass exact frame selection

For the default exact policy the bridge writes final target levels and
classifies actual source/target transitions during the same dirty-tile
walk. It selects DU, A2, DU4 or GL16 afterwards, without first preparing
an inexact preview or rescanning a frame for A2/DU4 eligibility. The
approximate motion policy retains its existing selection and dead band.
The host test covers all 256 old/new pairs for all four fast preferences,
plus mixed frames, and verifies the exact shared-frame sample.

### Indexed phase preparation

The default indexed worker now calculates PIN32 data directly from the
four actual transition codes in each indexed group. It no longer expands
four 257-entry pin tables before building the group table. Scalar and
staged fallback retain their existing tables, and INIT needs neither.
Tests compare all transition codes in each source position and the existing
full-buffer scalar/indexed equivalence test remains mandatory. No change
to physical scans, voltages or pixels selected for refresh.

### Absorb imminent local cleanup in a necessary grayscale update

When an exact sparse update already requires GL16 and a changed pixel
would reach its eighth transition, use one GC16 update for the changed
pixels and the same-final-shade one-pixel halo around those hot pixels.
This prevents a second same-level scrub of the same region after idle.
Unrelated due pixels keep their original cleanup deadline and counters.
Pure DU/A2/DU4 frames, large page turns, approximate preview and optional
HQ/Shadow filters retain their existing policies. No threshold increase,
extra resident allocation or waveform alteration. The bridge logs H and
uses the existing CLEAN command; counters reset only after ACK. Tests
cover the tile-boundary halo, unrelated cleanup, and fast binary frames.
GC16 is a complete factory update, but its optical appearance and the
latency of this combined policy still require physical comparison.
