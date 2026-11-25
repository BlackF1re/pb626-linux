# Preclear v2 (paired persistent worker)

Only for the previously tested v1 installation. The original and v1 binaries
remain untouched; the installer verifies the v1 session, saves it, installs
two uniquely named v2 binaries, then switches the session. Rollback restores v1.
No raw eMMC writes or changes to kernel/BT0.

The same historical source revision as v1 is used. New IPC INIT_PANEL ('I')
runs the already existing INIT path in the persistent worker; ACK is sent only
after the reset returns. The first logical RESET may use CLEAN on the wire
exactly once, after successful INIT, while retaining the full logical RESET
bookkeeping. On INIT failure a new worker is started and the normal RESET is
used. Later manual and recovery RESET remain unchanged. The bridge starts
before Matchbox and waits for INIT before the initial X capture.
The worker is built dynamically against Alpine musl in this experiment
(the historical original was statically cross-built); timing differences may
include toolchain effects. The UAPI header is copied from pinned upstream
facc87117511221bb61410e3f92ad8579697f736, blob
fa6037cd3d166575dbbe4d6d0c313543c3b9f884.

Expected profile: INIT begin, INIT_ACK, first wire=G, one RESET and one FULL,
no extra initial physical updates. Compare v1 ready 6.454 s, final ACK
6.447511 s, interval 11. No hardware validation of v2 yet.

Use the v2 artifact from CI, with install.ps1 -Mode Status / Install -Port COM13.
After cold boot read /run/pb626-desktop.log and ready mtime. Rollback mode
restores /root/pb626-xsession.preclear-v1; if serial transport or graphics fail
but console is reachable, restore this script directly with cp -p and sync.

## Startup tracing

When PB626_EPD_PROFILE is set, log the actual non-KEEP submitted pixel coordinates for non-RESET updates within two seconds of first ready. Bboxes use portrait coordinates with exclusive right/bottom, tiles are 32x32. Logging occurs after each ACK and may affect subsequent timing; use for localization, not performance benchmarking. The display policy and worker are unchanged. To move from the earlier v2 to this trace build, first run Rollback using the earlier artifact (no reboot needed), then install this artifact from v1.

## Async INIT experiment

Send INIT immediately, initialize gray/quantization tables and connect to Xorg, register damage and set up SHM while the worker resets the panel. Await the matching ACK before preparing or submitting any frame. If send or ACK fails, restart worker and use normal RESET. Subsequent update protocol, panel waveforms, Matchbox widgets and manual reset are unchanged. The primary metric is the first complete usable desktop (first successful FULL ACK/ready, provided the desktop itself needs no follow-up draw). Routine widget updates are not part of boot latency. Keep trace for verifying this; do not suppress widget updates. Measure X_SETUP_DONE versus INIT_ACK and first capture. As the first capture can become earlier, verify its content visually and check any follow-up damage. The prior trace build f00e477 is the rollback reference; transition via v1 using the installed artifact's rollback and the new artifact's install. No change to kernel, loader or files outside the existing experimental pair/session.
