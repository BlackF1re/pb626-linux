# First hardware qualification

This is an acceptance procedure, not a record of successful tests.
Keep the already hardware-verified BT0 and Menu FEL path. Do not flash
the source-built candidate or select deep sleep without an independent
recovery route. Use recovery RAM boots first.

## Recovery and storage

* Confirm the Windows COM or Linux ttyACM port automatically appears with
  USB VID:PID 0525:a4a7 and serial PB626RECOVERY. Check /etc/pb626-image-id,
  then /run/pb626-emmc-ready; the two checks have different meanings.
* Run installer Preflight against the original backup. Confirm CID and
  complete region sizes; verify the actual backup before changing anything.
* With the separate MMC0 recovery profile, use a disposable SD card.
  First back it up and verify the full hash; perform a write/readback on
  this disposable card only. Repeat after unplug/reinsert between sessions.
  Do not use an important SD or conflate this with reliable SD boot.
* Only then install with the previously qualified BT0 and retain the full
  backup. Confirm cold start and cold Menu FEL before further experiments.

## Baseline and power

Run `sudo pb626-profile-memory > baseline.txt` after the desktop has
settled for two minutes. Repeat with Wi-Fi associated, after a browser
session, and after returning to idle. This now records memory PSS,
MemAvailable, CMA, zram, PSI, PMIC battery samples, CPU idle counters
and E-Ink/USB runtime PM counters. Compare two snapshots over a known
interval; a single current sample is not a reliable energy measurement.
Battery current is not USB input current. For meaningful average power
measure unplugged battery draw over a fixed interval at matching charge,
temperature, frontlight and Wi-Fi configuration; for plugged charging
use an external USB meter if available. Do not claim measured values
from the estimated memory budget.

## Sleep and charge

Use the existing `pb626-charge probe` output for button versus cable cold
starts, also when the cable is already connected. Check the charging
state transitions before qualifying charge mode. For s2idle, first run
kernel PM test modes (if /sys/power/pm_test offers them) individually in
a controlled rescue-capable session. Restore pm_test to none before
actual suspend. Confirm the native lock screen and repeated wake, panel
rail state, frontlight, touch, buttons, MMC, USB and Wi-Fi association.
Record suspend_stats and dmesg privately. Don't enable deep suspend
until the matching source SPL can restore DRAM and FEL is independently
validated.

## Renderer

Use the same content (text, grayscale test image, scrolling and terminal),
temperature and WBF for every comparison. Test the default renderer
first, then opt-in DDX, HQ, Shadow and DMA release one at a time. Measure
input-to-display completion and PSS, count full cleans, inspect residual
images. Host pixel tests cannot establish optical ghosting or actual
energy saved. Disable each candidate after testing if unstable.

## Wi-Fi

The pinned rtl8xxxu has no USB suspend/resume callbacks and does not
advertise mac80211 PS. It disables RF on .stop but can still perform
register I/O (LED, debugfs, etc.) while interface is not running. Adding
supports_autosuspend alone would be incorrect. Full firmware LPS requires
reserved page / null-data and beacon wake handling, transition ordering
around scan, association and TX, and firmware/URB recovery after reset.
The current stock driver symbol evidence proves LPS/IPS implementation
exists, not that modern rtl8xxxu is equivalent or that USB autosuspend
is safe. Keep the current Wi-Fi driver and associated link alive; no
forced unbind or idle USB suspend during browsing. Qualification must
include ping and long-lived download/TCP connections, scan/reconnect,
system sleep and repeated idle transitions.
