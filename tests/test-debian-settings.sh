#!/bin/sh
# Mock sysfs on ordinary files. Never touch the host's devices.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/backlight/panel" "$tmp/leds/led" "$tmp/cpufreq/policy0/ondemand"
printf 'ondemand powersave performance\n' >"$tmp/cpufreq/policy0/scaling_available_governors"
printf '120000\n' >"$tmp/cpufreq/policy0/cpuinfo_min_freq"
printf '1008000\n' >"$tmp/cpufreq/policy0/cpuinfo_max_freq"
printf '400000\n' >"$tmp/cpufreq/policy0/scaling_min_freq"
printf '816000\n' >"$tmp/cpufreq/policy0/scaling_max_freq"
printf 'performance\n' >"$tmp/cpufreq/policy0/scaling_governor"
printf '50000\n' >"$tmp/cpufreq/policy0/ondemand/sampling_rate_min"
touch "$tmp/cpufreq/policy0/ondemand/sampling_rate" "$tmp/cpufreq/policy0/ondemand/up_threshold" "$tmp/cpufreq/policy0/ondemand/sampling_down_factor"
printf "1\n" >"$tmp/leds/led/max_brightness"
printf "1\n" >"$tmp/leds/led/brightness"
printf "none\n" >"$tmp/leds/led/trigger"
printf '100\n' >"$tmp/backlight/panel/max_brightness"
printf '0\n' >"$tmp/backlight/panel/brightness"
printf '4\n' >"$tmp/backlight/panel/bl_power"
sed -e "s|/var/lib/pb626|$tmp/state|g" \
    -e "s|/sys/class/backlight|$tmp/backlight|g" \
    -e "s|/sys/class/leds|$tmp/leds|g" \
    -e "s|/sys/devices/system/cpu/cpufreq|$tmp/cpufreq|g" \
    -e "s|/run/pb626-lock-indicator|$tmp/indicator|g" \
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
test "$(cat "$tmp/cpufreq/policy0/scaling_min_freq")" = 120000
test "$(cat "$tmp/cpufreq/policy0/scaling_max_freq")" = 1008000
test "$(cat "$tmp/cpufreq/policy0/scaling_governor")" = ondemand
test "$(cat "$tmp/cpufreq/policy0/ondemand/sampling_rate")" = 50000
test "$(cat "$tmp/cpufreq/policy0/ondemand/up_threshold")" = 75
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
test "$(admin power-key-status)" = lock
admin power-key ignore
test "$(admin power-key-status)" = ignore
if admin power-key s2idle; then exit 1; fi
admin power-key lock
admin led heartbeat
admin light-on
admin lock-indicator locked
test "$(cat "$tmp/leds/led/trigger")" = timer
test "$(cat "$tmp/backlight/panel/bl_power")" = 4
test "$(admin light-status)" = '1 72'
admin lock-indicator awake
test "$(cat "$tmp/leds/led/trigger")" = heartbeat
test "$(cat "$tmp/backlight/panel/bl_power")" = 0
test ! -e "$tmp/indicator"
touch "$tmp/qualified"
admin power-key s2idle
test "$(admin power-key-status)" = s2idle
admin desktop-settings arrows home menu balanced 24 30
admin desktop-status | grep -qx PB626_IDLE_MINUTES=30
test "$(admin button-bindings-status)" = 'Left none none Right none none Home none none Menu refresh none'
admin button-bindings Page_Up none F1 Page_Down none F2 keyboard Home none Escape refresh light-toggle
test "$(admin button-bindings-status)" = 'Page_Up none F1 Page_Down none F2 keyboard Home none Escape refresh light-toggle'
if admin button-bindings Left none none Right none none Home none none Menu refresh 'sh -c bad'; then exit 1; fi
admin button-bindings-reset
test "$(admin button-bindings-status)" = 'Left none none Right none none Home none none Menu refresh none'
test "$(admin battery-status)" = '10 3'
admin battery-settings 15 4
test "$(admin battery-status)" = '15 4'
for args in 'battery-settings 4 3' 'battery-settings 5 5' 'battery-settings 31 3' 'battery-settings 10 1'; do
    if admin $args; then echo "Invalid battery policy: $args" >&2; exit 1; fi
done
test "$(admin shutdown-image-status)" = white
if printf bad | admin shutdown-image-save; then exit 1; fi
test "$(admin shutdown-image-status)" = white
head -c 776192 /dev/zero | admin shutdown-image-save
test "$(admin shutdown-image-status)" = custom
test "$(wc -c <"$tmp/state/shutdown.pgm")" -eq 776208
if head -c 776193 /dev/zero | admin shutdown-image-save; then exit 1; fi
test "$(wc -c <"$tmp/state/shutdown.pgm")" -eq 776208
admin shutdown-image-clear
test "$(admin shutdown-image-status)" = white
echo "Debian frontlight persistence, native settings, battery policy and image validation passed"
