#!/bin/sh
set -eu
cd /run/pb626-preclear-persistent-test
p=/sbin/pb626-native-desktop
b=/root/pb626-native-desktop.pre-persistent
d=/usr/bin/pb626-desktop-preclear-persistent
x=/usr/bin/pb626-xsession-preclear-persistent
bridge=/usr/bin/pb626-x11-epd-preclear-persistent
check() { label=$1; shift; if "$@"; then echo "CHECK $label: OK"; else echo "CHECK $label: FAIL" >&2; exit 1; fi; }
hashcheck() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
check ORIGINAL_DESKTOP cmp -s /usr/bin/pb626-desktop desktop.original
check ORIGINAL_LAUNCHER cmp -s /root/pb626-native-desktop.pre-early native.original
check EARLY_DESKTOP cmp -s /usr/bin/pb626-desktop-preclear-early desktop.previous
check EARLY_SESSION cmp -s /usr/bin/pb626-xsession-preclear-early xsession.previous
check ASYNC_XSESSION hashcheck 6ae3298113f469047e3c136e6d1d8f9c4ea86ddb2fecd050ae4988dbef8b4f81 /usr/bin/pb626-xsession
check ASYNC_PROTOCOL test "$(/usr/bin/pb626-epd-preclear-v2 --protocol)" = pb626-epd-shm-4-preclear
for name in native.experimental desktop.persistent xsession.persistent; do check SYNTAX sh -n "$name"; done
if cmp -s "$p" native.early; then
    state=EARLY
elif cmp -s "$p" native.experimental; then
    state=PERSISTENT
    check PERSISTENT_DESKTOP cmp -s "$d" desktop.persistent
    check PERSISTENT_SESSION cmp -s "$x" xsession.persistent
    check PERSISTENT_BRIDGE cmp -s "$bridge" pb626-x11-epd-preclear-persistent
else
    echo 'Unexpected launcher; refusing change.' >&2; exit 1
fi
echo "CURRENT_LAUNCHER=$state"
case "$1" in
status) echo PRECLEAR_PERSISTENT_PREFLIGHT_OK ;;
install)
    check EARLY_LAUNCHER test "$state" = EARLY
    if [ -e "$b" ]; then check BACKUP cmp -s "$b" native.early; else cp -p "$p" "$b"; fi
    cp desktop.persistent "$d.new"
    cp xsession.persistent "$x.new"
    cp pb626-x11-epd-preclear-persistent "$bridge.new"
    chmod 755 "$d.new" "$x.new" "$bridge.new"
    check COPIED_DESKTOP cmp -s "$d.new" desktop.persistent
    check COPIED_SESSION cmp -s "$x.new" xsession.persistent
    check COPIED_BRIDGE cmp -s "$bridge.new" pb626-x11-epd-preclear-persistent
    mv "$d.new" "$d"; mv "$x.new" "$x"; mv "$bridge.new" "$bridge"
    cp -p "$p" "$p.new"
    cat native.experimental > "$p.new"
    check COPIED_LAUNCHER cmp -s "$p.new" native.experimental
    sync
    mv "$p.new" "$p"
    sync
    check INSTALLED_LAUNCHER cmp -s "$p" native.experimental
    check INSTALLED_DESKTOP cmp -s "$d" desktop.persistent
    check INSTALLED_SESSION cmp -s "$x" xsession.persistent
    check INSTALLED_BRIDGE cmp -s "$bridge" pb626-x11-epd-preclear-persistent
    echo PRECLEAR_PERSISTENT_INSTALLED_VERIFIED ;;
rollback)
    check BACKUP cmp -s "$b" native.early
    cp -p "$b" "$p.new"
    sh -n "$p.new"
    mv "$p.new" "$p"
    sync
    check RESTORED cmp -s "$p" "$b"
    echo PRECLEAR_PERSISTENT_ROLLBACK_VERIFIED ;;
*) exit 1;;
esac
