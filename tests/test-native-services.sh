#!/bin/sh
set -eu
grep -Fxq '::sysinit:/sbin/openrc sysinit' boot/pb626-native.inittab
grep -Fxq '::shutdown:/sbin/openrc shutdown' boot/pb626-native.inittab
! grep -q 'respawn:' boot/pb626-native.inittab
grep -Fxq 'supervisor=supervise-daemon' boot/native/init.d/pb626-desktop
grep -Fxq 'supervisor=supervise-daemon' boot/native/init.d/pb626-console
grep -Fq 'exec /sbin/getty' boot/pb626-native-console
# Reject malformed/unapproved helper calls before accessing any device or command.
for args in 'frontlight -1' 'frontlight 101' 'frontlight 08' 'frontlight 1+2' 'frontlight' 'reboot extra' 'shell' 'wifi-on extra'; do
    if sh boot/native/pb626-admin $args; then echo "Unsafe accepted command: $args" >&2; exit 1; fi
done
# The documented systemd key is TimerSlackNSec, not TimerSlackNS.
for unit in systemd-journald systemd-resolved systemd-timesyncd; do
    grep -Fxq 'TimerSlackNSec=25ms' "boot/debian/rootfs/usr/lib/systemd/system/$unit.service.d/60-pb626-timers.conf"
done
echo "Native service contracts passed"
