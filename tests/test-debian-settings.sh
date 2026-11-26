#!/bin/sh
# Mock sysfs on ordinary files. Never touch the host's devices.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/backlight/panel" "$tmp/leds/led"
printf "1\n" >"$tmp/leds/led/max_brightness"
printf "1\n" >"$tmp/leds/led/brightness"
printf "none\n" >"$tmp/leds/led/trigger"
printf '100\n' >"$tmp/backlight/panel/max_brightness"
printf '0\n' >"$tmp/backlight/panel/brightness"
printf '4\n' >"$tmp/backlight/panel/bl_power"
sed -e "s|/var/lib/pb626|$tmp/state|g" \
    -e "s|/sys/class/backlight|$tmp/backlight|g" \
    -e "s|/sys/class/leds|$tmp/leds|g" \
    -e "s|/etc/pb626/suspend-qualified|$tmp/qualified|g" \
    boot/debian/pb626-admin >"$tmp/admin"
admin() { sh "$tmp/admin" "$@"; }
test "$(admin light-status)" = '0 50'
admin restore-light
test "$(cat "$tmp/backlight/panel/brightness")" = 0
admin frontlight 37
test "$(admin light-status)" = '1 37'
test "$(cat "$tmp/backlight/panel/brightness")" = 37
test "$(cat "$tmp/backlight/panel/bl_power")" = 0
admin light-off
test "$(admin light-status)" = '0 37'
test "$(cat "$tmp/backlight/panel/bl_power")" = 4
admin restore-board
test "$(admin light-status)" = '0 37'
admin light-level 64
test "$(admin light-status)" = '0 64'
test "$(cat "$tmp/backlight/panel/bl_power")" = 4
admin light-level 37
admin light-on
test "$(admin light-status)" = '1 37'
test "$(cat "$tmp/backlight/panel/bl_power")" = 0
admin frontlight 1
test "$(cat "$tmp/backlight/panel/brightness")" = 1
admin frontlight 100
test "$(cat "$tmp/backlight/panel/brightness")" = 100
admin frontlight 0
test "$(admin light-status)" = '0 100'
printf '72\n' >"$tmp/state/frontlight"
admin restore-light
test "$(admin light-status)" = '1 72'
test "$(cat "$tmp/backlight/panel/brightness")" = 72
test "$(admin led-status)" = on
admin led off
test "$(admin led-status)" = off
printf "1\n" >"$tmp/leds/led/brightness"
admin restore-board
test "$(admin led-status)" = off
admin led on
test "$(admin led-status)" = on
admin desktop-settings pages keyboard escape photo 16 0
admin desktop-status | grep -qx PB626_BUTTONS=pages
admin desktop-status | grep -qx PB626_EPD_GRAY_PROFILE=photo
for args in 'frontlight -1' 'frontlight 101' 'frontlight 01' \
    'frontlight 1+2' 'light-on extra' 'light-level 0' 'governor bad' 'power-key bad' 'led bad' 'hostname -bad' 'ntp bad' \
    'desktop-settings bad keyboard menu ui 16 0' \
    'desktop-settings pages keyboard menu ui 16 5' 'suspend extra'; do
    if admin $args; then echo "Invalid command accepted: $args" >&2; exit 1; fi
done
touch "$tmp/qualified"
admin desktop-settings arrows home menu balanced 24 30
admin desktop-status | grep -qx PB626_IDLE_MINUTES=30
echo "Debian frontlight persistence, native settings and qualification gates passed"
