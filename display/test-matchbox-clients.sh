#!/bin/sh
# Disposable Xvfb session, no physical display or power-supply writes.
set -eu
keyboard_dir=$1
panel_dir=$2
export MB_KBD_CONFIG=$3
export PATH="$panel_dir:$keyboard_dir:$PATH"
export LC_ALL=C
tmp=$(mktemp -d)
export HOME="$tmp"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_CACHE_HOME="$tmp/cache"
kb= panel= battery=
cleanup() {
    for pid in "$battery" "$panel" "$kb"; do
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || :
    done
    for pid in "$battery" "$panel" "$kb"; do
        [ -z "$pid" ] || wait "$pid" 2>/dev/null || :
    done
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
"$keyboard_dir/matchbox-keyboard" &
kb=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$kb"
    if xwininfo -root -tree | grep -F '"Keyboard"'; then break; fi
    sleep 1
done
xwininfo -root -tree | grep -F '"Keyboard"'
kill "$kb"
wait "$kb" || :
kb=
# The panel owns an X window even without an external window manager.
xwininfo -root -tree >"$tmp/before"
"$panel_dir/matchbox-panel" --orientation south --size 48 --bgcolor white --no-session --default-apps "" &
panel=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$panel"
    xwininfo -root -tree >"$tmp/after"
    if ! cmp -s "$tmp/before" "$tmp/after"; then break; fi
    sleep 1
done
if cmp -s "$tmp/before" "$tmp/after"; then
    echo "Matchbox panel did not create a window" >&2
    exit 1
fi
"$panel_dir/mb-applet-battery" &
battery=$!
sleep 2
kill -0 "$panel" "$battery"
xwininfo -root -tree
echo "Matchbox keyboard, panel and battery applet ARM X11 smoke passed"
