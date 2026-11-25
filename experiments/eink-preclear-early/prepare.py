#!/usr/bin/env python3
import hashlib, pathlib, subprocess, sys
rev = 'c40c8f325f3095e9846920dbb08b02726fbebe81'
out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
here = pathlib.Path(__file__).resolve().parent
def read(name):
    return subprocess.check_output(['git','show',f'{rev}:display/{name}']).decode()
def change(s,old,new):
    if s.count(old)!=1:
        raise SystemExit(f'Unexpected source anchor: {old!r}')
    return s.replace(old,new,1)
def checked(s,expected):
    actual=hashlib.sha256(s.encode()).hexdigest()
    if actual!=expected:
        raise SystemExit(f'Installed source mismatch: {actual} != {expected}')
    return s
native=checked((here/'native.original').read_text(), 'a4f206ba050a9f219740344a82083605009ab342010c3c160fbde22468ed4238')
desktop=checked(read('pb626-desktop'),'87003e1aa7849f8cc6b3b98247f6af7cd5333ae5f7b4e4d8ac3b2f749d751aa2')
native_new=change(native,'/usr/bin/pb626-desktop "$wave"','/usr/bin/pb626-desktop-preclear-early "$wave"')
desktop_new=change(desktop, '''trap 'rm -f "$work"/Xauthority "$work"/xorg.conf "$work"/ready "$work"/layout; rmdir "$work"' EXIT
trap 'exit 1' HUP INT TERM''', '''reset_job=
# Never let a replacement session start while the standalone reset is live.
trap 'if [ -n "$reset_job" ]; then wait "$reset_job" || :; fi; rm -f "$work"/Xauthority "$work"/xorg.conf "$work"/ready "$work"/layout "$work"/preclear.result "$work"/preclear.result.new; rmdir "$work"' EXIT
trap 'exit 1' HUP INT TERM
(
    unset PB626_EPD_PRECLEARED
    rm -f /run/pb626-epd.levels
    read -r reset_begin rest < /proc/uptime
    echo "preclear-early: begin uptime=$reset_begin"
    result=FALLBACK
    if timeout 15 /usr/bin/pb626-epd "$waveform" reset &&
       [ "$(sha256sum /run/pb626-epd.levels 2>/dev/null | cut -d ' ' -f1)" = ff24da3ca6863961d16656258a89d897bba74bebf50f87021b82c2fa4748438d ]; then
        result=WHITE
    else
        rm -f /run/pb626-epd.levels
    fi
    read -r reset_end rest < /proc/uptime
    echo "preclear-early: $result uptime=$reset_end"
    printf '%s\\n' "$result" > "$work/preclear.result.new"
    mv "$work/preclear.result.new" "$work/preclear.result"
) &
reset_job=$!''')
desktop_new=change(desktop_new,'xinit /usr/bin/pb626-xsession ', 'xinit /usr/bin/pb626-xsession-preclear-early ')
session=read('pb626-xsession')
session=change(session,'pb626-x11-epd "$1" "$2" &\nscreen=$!\n','')
session=change(session,'''desktop=$!
trap 'kill "$wm" "$keyboard" "$screen" "$desktop" ${panel:+"$panel"} 2>/dev/null || true' EXIT
wait -n "$desktop" "$screen"'''.replace('\\$','$'),'''desktop=$!
screen=
trap 'kill "$wm" "$keyboard" "$desktop" ${panel:+"$panel"} ${screen:+"$screen"} 2>/dev/null || true' EXIT
unset PB626_EPD_PRECLEARED
result_file=${2%/*}/preclear.result
read -r session_begin rest < /proc/uptime
echo "preclear-early: clients_started uptime=$session_begin"
# The marker is published only after the reset process exits. If it never
# arrives, abort the session rather than open a second V4L2 renderer.
for n in $(seq 1 200); do
    [ ! -f "$result_file" ] || break
    sleep 0.1
done
if [ ! -f "$result_file" ]; then
    echo 'preclear-early: no reset result; abort session' >&2
    exit 1
fi
if [ "$(cat "$result_file")" = WHITE ] &&
   [ "$(sha256sum /run/pb626-epd.levels 2>/dev/null | cut -d ' ' -f1)" = ff24da3ca6863961d16656258a89d897bba74bebf50f87021b82c2fa4748438d ]; then
    export PB626_EPD_PRECLEARED=1
    echo 'preclear-early: WHITE_VERIFIED'
else
    rm -f /run/pb626-epd.levels
    echo 'preclear-early: FALLBACK_RESET'
fi
/usr/bin/pb626-x11-epd-preclear "$1" "$2" &
screen=$!
wait -n "$desktop" "$screen"'''.replace('\\$','$'))
for name,s in [('native.original',native),('native.experimental',native_new),('desktop.original',desktop),('desktop.early',desktop_new),('xsession.early',session)]:
    (out/name).write_text(s)
