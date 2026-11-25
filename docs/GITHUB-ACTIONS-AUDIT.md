> Historical audit, retained for CI cache and build context. The factory U-Boot workflow and p8/AXF installer described below were retired after successful autonomous cold boot on 2026-11-25. Current primary bootloader: [BT0-uncaged](../BT0-uncaged/README.md). This audit is not a current installation guide.

# GitHub Actions audit — PocketBook 626

Date: 2026-11-24. Scope: all six workflows under `.github/workflows/`.
Primary target: minimize repeated work and preserve **coherent** kernel,
modules, userland and E Ink worker versions. The production `main` E Ink
release is merge commit `3ec8923486df78b758cae07749fecc0a2fed1315`.

## Existing topology

| Workflow | Trigger | Build, dependencies | Cache before audit |
| --- | --- | --- | --- |
| `ci.yml` | push(main), PR, dispatch | shell and hardware probe | none; trivial job |
| `megi-fel.yml` | filtered main push/PR, dispatch | **parallel** kernel and Alpine, then `bundle` after both | `actions/cache@v4` for Alpine rootfs and pinned kernel/modules |
| `megi-desktop.yml` | filtered main push, successful FEL `workflow_run`, dispatch | Matchbox and Xorg after verified FEL artifact | previous desktop available **only** via explicit `desktop_run_id` |
| `restore.yml` | filtered main push, dispatch | restore scanner + full readback tests | none |
| `uboot.yml` | filtered main push, dispatch | pinned U-Boot + boot entry / optional eMMC-init payload | none |
| `userland.yml` | filtered main push, dispatch | pinned Alpine minirootfs + QEMU smoke | none |

## Improvements in the dedicated CI branch

1. **Desktop:** cache a *completed and verified* `pb626-desktop-root.cpio.gz`,
   keyed on the Matchbox build recipe, Alpine and rootfs assembly scripts,
   underlying FEL workflow, boot files and device-tree/kernel patches.
   On a cache hit, `build-megi-desktop.sh` restores the root and **still
   replaces kernel modules and E Ink worker from the currently selected
   FEL bundle and recompiles/tests the X11 bridge**. The cache is a
   userland speedup, not a cached full firmware image.
2. **Desktop consistency:** for a `workflow_run`, checkout the precise
   `head_sha` that generated the FEL artifact. Remove the embedded old
   run-id `45063328040`: if no verified successful FEL run is available,
   fail explicitly rather than silently using obsolete artifacts.
   The old early-exit deferral for simultaneous worker + desktop updates
   remains in place; the FEL completion is responsible for the real build.
3. **Desktop PR testing:** trigger the desktop build when its workflow or
   build script changes in a PR, so this optimization is CI-tested rather
   than being first exercised in production.
4. **U-Boot:** cache the compiled pinned U-Boot binary (key includes source
   revision and recipe hash). On cache hits, skip source fetch, configuration
   and expensive compilation, **but always rebuild and verify the current
   `bImage` entry stub and optional user-selected kernel payload**.
   Validate cached binary with SHA-256 and the original `eGON.BT0` header
   and size checks.
5. **Userland:** cache the exact Alpine 3.24.4 ARMv7 tarball and supplied
   `.sha256` file, then **always** verify SHA-256 even on cache hits.
6. **CI:** avoid unnecessary `apt-get update` when ShellCheck is already
   installed, validate both Desktop and DTB builder shell syntax,
   cancel superseded CI runs for the same branch/PR.

## Intentional nonchanges

- **Megi FEL:** existing Alpine/kernel caches already eliminate the expensive
  rebuilds on hits; both jobs execute concurrently. A source checkout and
  DTB recompile still happen even on kernel cache hits, since nine DTB
  variants derive from the exact current board source. Caching the whole
  Linux source tree would be large and needs measured net benefit.
- **Restore:** cross-compiled helper is small and the full readback test is
  intentionally not reused from cache. A cache would hide rather than
  accelerate this critical verification.
- **U-Boot and restore payloads are *not* installed to eMMC** by Actions.
- **The other workflows retain separate triggers**: unrelated changes
  should not force the full kernel+Desktop rebuild.

## Test and release acceptance

- `ci.yml` passes on the PR.
- Desktop workflow runs on PR and both cached-root creation and the
  restored-root path are tested via separate successful runs.
- U-Boot workflow runs on PR with cache miss and cache hit, retains the
  exact boot header and binary checks.
- Userland workflow verifies SHA-256 on both paths.
- Successful `main` FEL run emits `pb626-mainline-7.2-ram-bundle`;
  the subsequent Desktop `workflow_run` must produce a real desktop
  artifact, not just a green skipped run.
- No change to factory waveform, eMMC layout, voltage or VCOM.
- Track wall time and cache-hit markers from logs; don't claim performance
  improvements without an actual hit and time comparison.

This audit distinguishes **implemented caching** from **measured cache
savings**. Warm cache results depend on runner/image and GitHub cache scope.
