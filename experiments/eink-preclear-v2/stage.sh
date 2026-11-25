#!/bin/sh
set -eu
cd /run/pb626-preclear-v2-test
p=/usr/bin/pb626-xsession
b=/root/pb626-xsession.pre-order
v1=/root/pb626-xsession.preclear-v1
bridge=/usr/bin/pb626-x11-epd-preclear-v2
worker=/usr/bin/pb626-epd-preclear-v2
check() { label=$1; shift; if "$@"; then echo "CHECK $label: OK"; else echo "CHECK $label: FAIL" >&2; exit 1; fi; }
check ORIGINAL_BACKUP cmp -s "$b" xsession.original
check ORIGINAL_PROTOCOL test "$(/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-3
check PROFILE grep -Fq 'export PB626_EPD_PROFILE=1 PB626_EPD_RENDER=indexed' /sbin/pb626-native-desktop
check V1_BRIDGE test -x /usr/bin/pb626-x11-epd-preclear
check EXPERIMENT_SCRIPT sh -n xsession.experimental
chmod 755 pb626-epd-preclear-v2
check V2_PROTOCOL test "$(./pb626-epd-preclear-v2 --protocol)" = pb626-epd-shm-4-preclear
if cmp -s "$p" xsession.v1; then
    state=V1
elif cmp -s "$p" xsession.experimental; then
    state=V2
    check V2_BRIDGE cmp -s "$bridge" pb626-x11-epd-preclear-v2
    check V2_WORKER cmp -s "$worker" pb626-epd-preclear-v2
else
    echo 'Unexpected Xsession; expected hardware-tested v1 or v2.' >&2; exit 1
fi
echo "CURRENT_XSESSION=$state"
case "$1" in
status) echo PRECLEAR_V2_PREFLIGHT_OK ;;
install)
    check V1_SESSION test "$state" = V1
    if [ -e "$v1" ]; then check V1_BACKUP cmp -s "$v1" xsession.v1; else cp -p "$p" "$v1"; fi
    for name in pb626-x11-epd-preclear-v2 pb626-epd-preclear-v2; do
        cp "$name" "/usr/bin/$name.new"
        chmod 755 "/usr/bin/$name.new"
        check COPIED_BINARY cmp -s "$name" "/usr/bin/$name.new"
        mv "/usr/bin/$name.new" "/usr/bin/$name"
    done
    cp -p "$p" "$p.new"
    cat xsession.experimental > "$p.new"
    sh -n "$p.new"
    check COPIED_SESSION cmp -s "$p.new" xsession.experimental
    mv "$p.new" "$p"
    sync
    check INSTALLED_SESSION cmp -s "$p" xsession.experimental
    check INSTALLED_BRIDGE cmp -s "$bridge" pb626-x11-epd-preclear-v2
    check INSTALLED_WORKER cmp -s "$worker" pb626-epd-preclear-v2
    echo PRECLEAR_V2_INSTALLED_VERIFIED ;;
rollback)
    check V1_BACKUP cmp -s "$v1" xsession.v1
    cp -p "$v1" "$p.new"
    sh -n "$p.new"
    mv "$p.new" "$p"
    sync
    check RESTORED_V1 cmp -s "$p" "$v1"
    echo PRECLEAR_V2_ROLLBACK_VERIFIED ;;
*) exit 1;;
esac
