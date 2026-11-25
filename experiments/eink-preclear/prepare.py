#!/usr/bin/env python3
"""Patch the exact installed bridge revision, not the current main worker."""
import pathlib, subprocess, sys
rev = 'c40c8f325f3095e9846920dbb08b02726fbebe81'
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
def read(name):
    return subprocess.check_output(['git','show',f'{rev}:display/{name}']).decode()
def change(s, old, new):
    if s.count(old)!=1: raise SystemExit(f'Unexpected source: anchor count {s.count(old)} for {old!r}')
    return s.replace(old,new,1)
bridge = read('pb626-x11-epd.c')
bridge = change(bridge, '\tint dirty = 1, focus_changed = 1, has_frame = 0, pending = 0;', '\tint dirty = 1, focus_changed = 1, has_frame = 0, pending = 0;\n\t/* Experimental: a separately acknowledged INIT left a white panel. */\n\tconst char *preclear = getenv("PB626_EPD_PRECLEARED");\n\tint precleared = preclear && !strcmp(preclear, "1");')
bridge = change(bridge, '\t\t\tif (submit(&worker, command)) {', '\t\t\tuint8_t wire = command;\n\t\t\tif (precleared && !has_frame && command == RESET && !controls.clean_requested)\n\t\t\t\twire = CLEAN;\n\t\t\tprecleared = 0; /* Never skip a recovery or manual reset. */\n\t\t\tif (profile && !has_frame)\n\t\t\t\tfprintf(stderr, "preclear: first wire=%c mono_us=%llu\\n", wire, (unsigned long long)now_us());\n\t\t\tif (submit(&worker, wire)) {')
(out/'pb626-x11-epd.c').write_text(bridge)
for name in ['pb626-epd.h','test-pb626-x11-epd.c']:
    (out/name).write_text(read(name))
orig=read('pb626-xsession')
script=orig
script=change(script,'matchbox-window-manager -theme PB626 -use_titlebar yes &', '''# Experiment: INIT in parallel with the X clients. State is RAM-only.
unset PB626_EPD_PRECLEARED
rm -f /run/pb626-epd.levels
read -r reset_begin rest < /proc/uptime
echo "preclear: begin uptime=$reset_begin"
timeout 15 /usr/bin/pb626-epd "$1" reset &
reset_pid=$!
matchbox-window-manager -theme PB626 -use_titlebar yes &''')
script=change(script,'pb626-x11-epd "$1" "$2" &\nscreen=$!\n','')
script=change(script,'desktop=$!\n','''desktop=$!
if wait "$reset_pid" && [ "$(sha256sum /run/pb626-epd.levels 2>/dev/null | cut -d ' ' -f1)" = ff24da3ca6863961d16656258a89d897bba74bebf50f87021b82c2fa4748438d ]; then
    export PB626_EPD_PRECLEARED=1
    read -r reset_end rest < /proc/uptime
    echo "preclear: WHITE_VERIFIED uptime=$reset_end"
else
    rm -f /run/pb626-epd.levels
    echo 'preclear: FALLBACK_RESET'
fi
/usr/bin/pb626-x11-epd-preclear "$1" "$2" &
screen=$!
''')
(out/'xsession.original').write_text(orig)
(out/'xsession.experimental').write_text(script)
