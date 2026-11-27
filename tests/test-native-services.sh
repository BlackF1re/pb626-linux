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
# Direct systemctl suspend must fail, not silently skip the prepare unit.
sleep_unit=boot/debian/rootfs/usr/lib/systemd/system/pb626-sleep.service
grep -Fxq "AssertPathExists=/etc/pb626/suspend-qualified" "$sleep_unit"
grep -Fxq "Requisite=pb626-desktop.service" "$sleep_unit"
grep -Fxq "Requires=pb626-sleep.service" boot/debian/rootfs/usr/lib/systemd/system/systemd-suspend.service.d/pb626.conf
# Renderer isolation must not protect the entire app service by accident.
unitdir=boot/debian/rootfs/usr/lib/systemd/system
grep -Fxq 'Slice=pb626.slice' "$unitdir/pb626-desktop.service"
grep -Fxq 'MemoryLow=16M' "$unitdir/pb626.slice"
! grep -q '^MemoryLow=' "$unitdir/pb626-desktop.service"
grep -Fq -- '--property=CPUWeight=200 --property=MemoryLow=16M' display/pb626-desktop
grep -Fq -- '--property=BindsTo=pb626-desktop.service' display/pb626-desktop
grep -Fq -- '--property=After=pb626-desktop.service' display/pb626-desktop
# Device readiness is a bounded PID 1 dependency; no Debian video polling.
grep -Fxq 'BindsTo=dev-video0.device' "$unitdir/pb626-desktop.service"
grep -Fq 'dev-video0.device' "$unitdir/pb626-desktop.service"
grep -Fxq 'RuntimeDirectory=pb626-desktop' "$unitdir/pb626-desktop.service"
grep -Fxq 'JobTimeoutSec=30s' "$unitdir/dev-video0.device.d/60-pb626.conf"
grep -Fq 'ENV{SYSTEMD_WANTS}+="pb626-desktop.service"' boot/debian/rootfs/usr/lib/udev/rules.d/72-pb626-display.rules
# The private DDX must never replace the package driver by default.
grep -Fq 'unset PB626_DDX_SHARED' display/pb626-desktop
grep -Fq '/etc/pb626/ddx-shared-qualified' display/pb626-desktop
grep -Fq -- '-modulepath /usr/lib/pb626/xorg,/usr/lib/xorg/modules' display/pb626-desktop
grep -Fq 'apt-get source --only-source xserver-xorg-video-dummy=1:0.4.0-1' scripts/compile-debian-native.sh
grep -Fq -- 'patch --fuzz=0 -p1 < ../xorg-dummy-pb626-shared.patch' scripts/compile-debian-native.sh
# The optional ELAN device must not make missing touch a fatal dependency.
grep -Fq 'Wants=pb626-board.service dev-input-pb626_touch.device' "$unitdir/pb626-desktop.service"
grep -Fxq 'JobTimeoutSec=5s' "$unitdir/dev-input-pb626_touch.device.d/60-pb626.conf"
grep -Fq 'ENV{SYSTEMD_ALIAS}+="/dev/input/pb626_touch"' boot/debian/rootfs/usr/lib/udev/rules.d/73-pb626-touch.rules
! grep -q '^ExecStartPost=/bin/sleep' "$unitdir/pb626-poweroff-screen.service"
grep -Fq 'systemd-analyze --man=no --generators=no --recursive-errors=one verify' scripts/build-debian-rootfs.sh
# Udev-activated native services must wait for the boot-mode decision.
for unit in pb626-board.service pb626-desktop.service pb626-battery.service pb626-battery-warning.service pb626-usb.service; do
    grep -Fxq 'Requires=pb626-boot-select.service' "$unitdir/$unit"
    grep -Fxq 'After=pb626-boot-select.service' "$unitdir/$unit"
    grep -Fxq 'ConditionPathExists=/run/pb626-normal-boot' "$unitdir/$unit"
done
grep -Fxq 'ConditionPathExists=/run/pb626-charge-mode' "$unitdir/pb626-charge.service"
grep -Fxq 'After=local-fs.target pb626-desktop.service pb626-charge.service' "$unitdir/pb626-poweroff-screen.service"
grep -Fxq 'ctl set-default pb626-boot.target' scripts/build-debian-rootfs.sh
# Debian's packaged Matchbox Desktop 2.x uses --mode; legacy flags terminate
# the client and consequently terminate the xinit-managed session.
grep -Fq 'DISPLAY is unset' display/pb626-xsession
grep -Fq 'cannot connect to X server' display/pb626-xsession
grep -Fxq '    supervise_client matchbox-desktop --mode desktop &' display/pb626-xsession
grep -Fq '    supervise_client matchbox-desktop --bg col-solid:white' display/pb626-xsession
# A broken X client must not terminate the X session; only X server loss or the legacy local renderer is fatal.
grep -Fxq '    export MB_KBD_CONFIG=/usr/share/pb626/matchbox-keyboard/keyboard-us.xml' display/pb626-xsession
grep -Fxq '    supervise_client matchbox-keyboard --daemon &' display/pb626-xsession
grep -Fxq 'supervise_client matchbox-window-manager -theme PB626 -use_titlebar yes &' display/pb626-xsession
grep -Fxq 'if [ -n "$screen" ]; then' display/pb626-xsession
grep -Fxq '    while xset q >/dev/null 2>&1; do' display/pb626-xsession
! grep -q '^wait -n ' display/pb626-xsession
grep -Fq 'while :; do' display/pb626-xsession
! grep -Fq 'restart budget exhausted' display/pb626-xsession
grep -Fq 'display/keyboard-us.xml' scripts/build-debian-rootfs.sh
python3 tests/test-matchbox-keyboard-layout.py
# The physical PE8 power LED is the DTS node named "led"; ignore USB LEDs.
grep -Fq 'led=/sys/class/leds/led' boot/debian/pb626-admin
grep -Fq 'power_led=/sys/class/leds/led' boot/init-megi
grep -Fq 'power_led=/sys/class/leds/led' boot/native/init.d/pb626-board
! grep -Fq 'for led in /sys/class/leds/*' boot/init-megi
! grep -Fq 'for led in /sys/class/leds/*' boot/native/init.d/pb626-board
echo "Native service contracts passed"
