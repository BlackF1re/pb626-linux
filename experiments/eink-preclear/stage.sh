#!/bin/sh
set -eu
cd /run/pb626-preclear-test
p=/usr/bin/pb626-xsession
b=/root/pb626-xsession.pre-order
alt=/usr/bin/pb626-x11-epd-preclear
check() { label=$1; shift; if "$@"; then echo "CHECK $label: OK"; else echo "CHECK $label: FAIL" >&2; exit 1; fi; }
check ORIGINAL_BACKUP cmp -s "$b" xsession.original
check PROTOCOL test "$(/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-3
check PROFILE grep -Fq 'export PB626_EPD_PROFILE=1 PB626_EPD_RENDER=indexed' /sbin/pb626-native-desktop
check ORIGINAL_BRIDGE test -x /usr/bin/pb626-x11-epd
check EXPERIMENT_SCRIPT sh -n xsession.experimental
if cmp -s "$p" xsession.original; then
    echo CURRENT_XSESSION=ORIGINAL
elif cmp -s "$p" xsession.experimental; then
    echo CURRENT_XSESSION=EXPERIMENTAL
    check EXPERIMENT_BINARY cmp -s "$alt" pb626-x11-epd-preclear
else
    echo 'Unexpected Xsession; restore pre-order first.' >&2; exit 1
fi
case "$1" in
status) echo PRECLEAR_PREFLIGHT_OK ;;
install)
    check ORIGINAL_SESSION cmp -s "$p" xsession.original
    cp pb626-x11-epd-preclear "$alt.new"
    chmod 755 "$alt.new"
    check COPIED_BINARY cmp -s "$alt.new" pb626-x11-epd-preclear
    mv "$alt.new" "$alt"
    cp -p "$p" "$p.new"
    cat xsession.experimental > "$p.new"
    check COPIED_SCRIPT cmp -s "$p.new" xsession.experimental
    sh -n "$p.new"
    mv "$p.new" "$p"
    sync
    check INSTALLED_SCRIPT cmp -s "$p" xsession.experimental
    check INSTALLED_BINARY cmp -s "$alt" pb626-x11-epd-preclear
    echo PRECLEAR_INSTALLED_VERIFIED ;;
rollback)
    cp -p "$b" "$p.new"
    sh -n "$p.new"
    mv "$p.new" "$p"
    sync
    check RESTORED cmp -s "$b" "$p"
    echo PRECLEAR_ROLLBACK_VERIFIED ;;
*) exit 1;;
esac
