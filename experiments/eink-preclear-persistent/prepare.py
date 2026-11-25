#!/usr/bin/env python3
import pathlib, subprocess, sys
here=pathlib.Path(__file__).resolve().parent
out=pathlib.Path(sys.argv[1]); out.mkdir(parents=True,exist_ok=True)
v2=out/'v2'
early=out/'early'
subprocess.run([sys.executable,str(here.parent/'eink-preclear-v2'/'prepare.py'),str(v2)],check=True)
subprocess.run([sys.executable,str(here.parent/'eink-preclear-early'/'prepare.py'),str(early)],check=True)
def change(s,old,new):
    if s.count(old)!=1:
        raise SystemExit(f'Unexpected anchor ({s.count(old)}): {old!r}')
    return s.replace(old,new,1)
bridge=(v2/'pb626-x11-epd.c').read_text()
# Inherited lock descriptor remains held by the worker even if the bridge dies.
# This prevents a respawn from overlapping a still finishing physical update.
bridge=change(bridge,'#include <sys/mman.h>','#include <sys/mman.h>\n#include <sys/file.h>')
bridge=change(bridge, '\t/* Start the persistent worker before expensive gray tables and X setup. */', '''	/* Never overlap a renderer from an aborted experimental session. */
	int lock_fd = open("/run/pb626-preclear-persistent.lock", O_CREAT | O_RDWR, 0600);
	if (lock_fd < 0 || flock(lock_fd, LOCK_EX | LOCK_NB) < 0) {
		fprintf(stderr, "preclear-persistent: renderer lock unavailable\\n");
		return EXIT_FAILURE;
	}
	/* Start the persistent worker before expensive gray tables and X setup. */''')
bridge=change(bridge, '\tDisplay *display = XOpenDisplay(NULL);', '''	/* The wrapper launches us before xinit. Wait for the X session handoff,
	 * not for any particular GUI application or window to become ready. */
	const char *marker = getenv("PB626_EPD_SESSION_STARTED");
	uint64_t deadline = now_us() + 15000000ULL;
	if (!marker) {
		stop_worker(&worker);
		return EXIT_FAILURE;
	}
	while (access(marker, F_OK) && now_us() < deadline)
		usleep(20000);
	if (access(marker, F_OK)) {
		fprintf(stderr, "preclear-persistent: session marker timed out\\n");
		stop_worker(&worker);
		return EXIT_FAILURE;
	}
	Display *display = XOpenDisplay(NULL);''')
bridge=bridge.replace('preclear-async:', 'preclear-persistent:')
# Worker executable is the existing installed, hardware-tested async v2.
# It inherits the lock, and INIT doesn't inspect the shared frame.
desktop=(early/'desktop.original').read_text()
desktop=change(desktop,'''trap 'rm -f "$work"/Xauthority "$work"/xorg.conf "$work"/ready "$work"/layout; rmdir "$work"' EXIT''','''bridge_pid=
trap 'if [ -n "$bridge_pid" ]; then kill "$bridge_pid" 2>/dev/null || :; wait "$bridge_pid" || :; fi; rm -f "$work"/Xauthority "$work"/xorg.conf "$work"/ready "$work"/layout "$work"/clients.started; rmdir "$work"' EXIT''')
desktop=change(desktop,'''xinit /usr/bin/pb626-xsession "$waveform" "$work/ready" --''','''export PB626_EPD_SESSION_STARTED="$work/clients.started"
DISPLAY=:0 /usr/bin/pb626-x11-epd-preclear-persistent "$waveform" "$work/ready" &
bridge_pid=$!
export PB626_EPD_BRIDGE_PID="$bridge_pid"
xinit /usr/bin/pb626-xsession-preclear-persistent "$waveform" "$work/ready" --''')
session=(v2/'xsession.original').read_text()
session=change(session,'pb626-x11-epd "$1" "$2" &\nscreen=$!\n','')
# Preserve the original GUI client launch order; only move EPD ownership.
session=change(session,'''trap 'kill "$wm" "$keyboard" "$screen" "$desktop" ${panel:+"$panel"} 2>/dev/null || true' EXIT
wait -n "$desktop" "$screen"'''.replace('\\$','$'),'''watcher=
trap 'kill "$wm" "$keyboard" "$desktop" ${panel:+"$panel"} ${watcher:+"$watcher"} 2>/dev/null || true' EXIT
: "${PB626_EPD_BRIDGE_PID:?missing bridge pid}"
: "${PB626_EPD_SESSION_STARTED:?missing marker}"
# The wrapper owns the bridge; xsession owns Matchbox clients.
: > "$PB626_EPD_SESSION_STARTED"
read -r started rest < /proc/uptime
echo "preclear-persistent: clients_started uptime=$started"
(while kill -0 "$PB626_EPD_BRIDGE_PID" 2>/dev/null; do sleep 0.2; done) &
watcher=$!
wait -n "$desktop" "$watcher"'''.replace('\\$','$'))
native=change((early/'native.original').read_text(),'/usr/bin/pb626-desktop "$wave"','/usr/bin/pb626-desktop-preclear-persistent "$wave"')
for name,s in [('pb626-x11-epd.c',bridge),('native.original',(early/'native.original').read_text()),('native.early',(early/'native.experimental').read_text()),('native.experimental',native),('desktop.original',(early/'desktop.original').read_text()),('desktop.previous',(early/'desktop.early').read_text()),('xsession.previous',(early/'xsession.early').read_text()),('desktop.persistent',desktop),('xsession.persistent',session)]:
    (out/name).write_text(s)
for name in ['pb626-epd.h','test-pb626-x11-epd.c']:
    (out/name).write_bytes((v2/name).read_bytes())
