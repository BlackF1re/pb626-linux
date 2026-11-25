# Native boot / E Ink startup experiment — final results

Hardware: late ELAN/eMMC PocketBook 626 Plus, 256 MiB, native Alpine,
MBUS-fixed kernel 7.2.0-pb626-eink-builtin-mbusfix-gfacc87117511-dirty.
All timings below are relative to kernel monotonic time, not power-button
time. Single trials or a selected best trial; cold/warm starts and build
toolchains differ. Do not interpret small differences as a controlled
benchmark.

## Measurements

| Variant | First ready mtime (s) | Last startup physical ACK (s) | Startup scans |
|---|---:|---:|---:|
| Scalar | 6.183 | 7.244443 | 176 |
| Indexed (warm) | 5.962 | 7.021801 | 176 |
| Desktop first | 6.359 | 7.418867 | 176 |
| Preclear v1 | 6.454 | 6.447511 | 121 |
| Synchronous v2 (trial 2) | 6.138 | 7.006227 | 176 |
| Async v2 | 6.152 | 6.145140 | 121 |
| Early standalone | 5.419 | 6.853346 | 191 |
| Persistent Generic | 4.863 | 6.555498 | 206 |

Ready is written after the first acknowledged frame, not after all icons
or applets finish drawing. ACK can precede ready by several milliseconds.
Later widget refreshes are excluded; e.g. Async v2 next refreshed at
35–36 s. The initial full frame may be incomplete.

## Final installed experiment

Source commit 9802a3f6435a5940ca6b8e44f2b4d200d3eca7b2.
CI run 45675934476, artifact 15050903994
(pb626-preclear-persistent-generic), zip SHA256
50787bf49ffaddb30e51d9c97a5d91e5bfd31edb47efaab4b958abc35c7db778.
Requires the previously installed async v2 worker and early-launcher
installation; it is not a fresh-device installer.

| Event | Seconds |
|---|---:|
| INIT begin | 2.368460 |
| Session clients spawned | 3.45 |
| X setup done | 3.479644 |
| INIT ACK | 3.566185 |
| First capture | 3.569184 |
| First wire CLEAN (G) | 3.947523 |
| FULL ACK | 4.843578 |
| ready mtime | 4.863 |
| DU, left panel 1446 px | 5.281449 |
| DU, upper desktop and right panel 15704 px | 5.697280 |
| DU, right widget 928 px | 5.923117 |
| GL16, 39424 px | 6.555498 |

One RESET (81 scans), one FULL (40), three DU (15 each), and one
GL16 (40); 206 scans, no scan start retries. The second DU included
the upper desktop (tiles ty0–3); exact icon completeness/appearance
at 5.697 s is inferred from location, not verified by an image.
GL16 settles grayscale, with no additional X capture.

The persistent worker is launched before xinit and owns the panel
throughout the session. The existing GUI client launch order is kept.
A generic X session handoff is used; there is no applet/icon-specific
readiness gate or damage suppression. The priority is rapid usable
desktop, not suppression of subsequent applet updates.

## Decision / limitations

End startup optimization at this point. Persistent Generic is the
fastest measured first-frame variant, with earlier visible desktop
updates, and the preferred experimental endpoint subject to normal
visual/input checks. Async v2 is a conservative alternative: its first
frame was already stable and finished at 6.152 s. No claim that Generic
has the fastest fully settled grayscale desktop. No further tuning,
delays, waveform changes, or GUI-specific policy are warranted here.

Final Generic boot profile is confirmed; interactive/manual-reset
validation on this revision and repeated cold trials are not recorded.
V1 was separately validated by the operator. Existing installers,
sources and rollback points are retained. The PR is experimental;
a mainline integration/fresh-install path has not been validated.

Rollback Generic -> Early with the matching persistent artifact
install.ps1 -Mode Rollback -Port COM13; Early -> Async with the early
artifact install.ps1 -Mode Rollback -Port COM13. Use matching artifact
manifests and cold boot after restoring the desired launcher. No
kernel, SPL, raw eMMC, or waveform changes in these experiments.
