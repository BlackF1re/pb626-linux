#!/bin/sh
set -eu
cd /run/pb626-preclear-early-test
p=/sbin/pb626-native-desktop
b=/root/pb626-native-desktop.pre-early
d=/usr/bin/pb626-desktop-preclear-early
x=/usr/bin/pb626-xsession-preclear-early
check() { label=$1; shift; if "$@"; then echo "CHECK $label: OK"; else echo "CHECK $label: FAIL" >&2; exit 1; fi; }
hashcheck() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
check ORIGINAL_DESKTOP cmp -s /usr/bin/pb626-desktop desktop.original
check ASYNC_XSESSION hashcheck 6ae3298113f469047e3c136e6d1d8f9c4ea86ddb2fecd050ae4988dbef8b4f81 /usr/bin/pb626-xsession
check V1_BRIDGE hashcheck 9e11b2c6b9a47fec75222459880522e1d9432f1d03427e7263370894662707db /usr/bin/pb626-x11-epd-preclear
check ORIGINAL_PROTOCOL test "$(/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-3
check ASYNC_PROTOCOL test "$(/usr/bin/pb626-epd-preclear-v2 --protocol)" = pb626-epd-shm-4-preclear
for name in native.original native.experimental desktop.early xsession.early; do check SYNTAX sh -n "$name"; done
if cmp -s "$p" native.original; then
    state=ASYNC
elif cmp -s "$p" native.experimental; then
    state=EARLY
    check EARLY_DESKTOP cmp -s "$d" desktop.early
    check EARLY_SESSION cmp -s "$x" xsession.early
else
    echo 'Unexpected native launcher; refusing change.' >&2
    exit 1
fi
echo "CURRENT_LAUNCHER=$state"
case "$1" in
status) echo PRECLEAR_EARLY_PREFLIGHT_OK ;;
install)
    check ASYNC_LAUNCHER test "$state" = ASYNC
    if [ -e "$b" ]; then check BACKUP cmp -s "$b" native.original; else cp -p "$p" "$b"; fi
    cp desktop.early "$d.new"
    cp xsession.early "$x.new"
    chmod 755 "$d.new" "$x.new"
    check COPIED_DESKTOP cmp -s "$d.new" desktop.early
    check COPIED_SESSION cmp -s "$x.new" xsession.early
    mv "$d.new" "$d"
    mv "$x.new" "$x"
    cp -p "$p" "$p.new"
    cat native.experimental > "$p.new"
    check COPIED_LAUNCHER cmp -s "$p.new" native.experimental
    sync
    mv "$p.new" "$p"
    sync
    check INSTALLED_LAUNCHER cmp -s "$p" native.experimental
    check INSTALLED_DESKTOP cmp -s "$d" desktop.early
    check INSTALLED_SESSION cmp -s "$x" xsession.early
    echo PRECLEAR_EARLY_INSTALLED_VERIFIED ;;
rollback)
    check BACKUP cmp -s "$b" native.original
    cp -p "$b" "$p.new"
    sh -n "$p.new"
    mv "$p.new" "$p"
    sync
    check RESTORED cmp -s "$p" "$b"
    echo PRECLEAR_EARLY_ROLLBACK_VERIFIED ;;
*) exit 1;;
esac
