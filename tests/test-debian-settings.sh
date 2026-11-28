#!/bin/sh
# Mock sysfs on ordinary files. Never touch the host's devices.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/backlight/panel" "$tmp/leds/led" "$tmp/leds/rtl8xxxu-usb1-1" "$tmp/cpufreq/policy0/ondemand"
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
# Simulate the second LED class device created by rtl8xxxu. It is not a
# board indicator and must remain untouched by every PB626 LED operation.
printf "1\n" >"$tmp/leds/rtl8xxxu-usb1-1/max_brightness"
printf "1\n" >"$tmp/leds/rtl8xxxu-usb1-1/brightness"
printf "none\n" >"$tmp/leds/rtl8xxxu-usb1-1/trigger"
printf '100\n' >"$tmp/backlight/panel/max_brightness"
printf '0\n' >"$tmp/backlight/panel/brightness"
printf '4\n' >"$tmp/backlight/panel/bl_power"
mkdir -p "$tmp/bin" "$tmp/power_supply/battery" "$tmp/power_supply/usb" "$tmp/run/pb626-desktop"
cat >"$tmp/bin/systemctl" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >>"$PB626_TEST_SYSTEMCTL_LOG"
exit 0
MOCK
chmod 755 "$tmp/bin/systemctl"
export PB626_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log"
: >"$PB626_TEST_SYSTEMCTL_LOG"
sed -e "s|export PATH=/sbin:/bin:/usr/sbin:/usr/bin|export PATH=$tmp/bin:/sbin:/bin:/usr/sbin:/usr/bin|" \
    -e "s|/sys/class/power_supply|$tmp/power_supply|g" \
    -e "s|/proc/uptime|$tmp/uptime|g" \
    -e "s|/run/pb626-battery-|$tmp/run/pb626-battery-|g" \
    -e "s|/run/pb626-desktop/ready|$tmp/run/pb626-desktop/ready|g" \
    -e "s|/var/lib/pb626|$tmp/state|g" \
    -e "s|/sys/class/backlight|$tmp/backlight|g" \
    -e "s|/sys/class/leds|$tmp/leds|g" \
    -e "s|/sys/devices/system/cpu/cpufreq|$tmp/cpufreq|g" \
    -e "s|/run/pb626-lock-indicator|$tmp/indicator|g" \
    -e "s|/etc/pb626/suspend-qualified|$tmp/qualified|g" \
    -e "s|/etc/pb626/mixed-waveform-qualified|$tmp/mixed-qualified|g" \
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
test "$(cat "$tmp/leds/rtl8xxxu-usb1-1/brightness")" = 1
test "$(cat "$tmp/leds/rtl8xxxu-usb1-1/trigger")" = none
# If the PE8 node is absent, do not fall back to the Wi-Fi driver's LED.
mv "$tmp/leds/led" "$tmp/leds/led-missing"
test "$(admin led-status)" = unavailable
if admin led on; then echo "Wi-Fi LED was incorrectly selected as the power LED" >&2; exit 1; fi
mv "$tmp/leds/led-missing" "$tmp/leds/led"
test "$(cat "$tmp/leds/rtl8xxxu-usb1-1/brightness")" = 1
test "$(cat "$tmp/leds/rtl8xxxu-usb1-1/trigger")" = none
admin desktop-settings pages keyboard escape photo 16 0
admin desktop-status | grep -qx PB626_BUTTONS=pages
admin desktop-status | grep -qx PB626_EPD_GRAY_PROFILE=photo
admin desktop-status | grep -qx PB626_EPD_FAST_MODE=du
admin desktop-settings pages keyboard escape mono 16 0 auto
admin desktop-status | grep -qx PB626_EPD_GRAY_PROFILE=mono
admin desktop-status | grep -qx PB626_EPD_FAST_MODE=auto
admin desktop-display photo 24 auto cie-lstar 1.2 0 0
admin desktop-buttons arrows home menu
admin desktop-status | grep -qx PB626_EPD_GAMMA=1.2
admin desktop-status | grep -qx PB626_EPD_TONE=cie-lstar
admin desktop-status | grep -qx PB626_BUTTONS=arrows
admin desktop-status | grep -qx PB626_XORG_DEPTH=24
if admin desktop-display photo 24 auto srgb 1.0 0 1; then exit 1; fi
touch "$tmp/mixed-qualified"
admin desktop-display photo 24 auto srgb 1.0 0 1
if admin desktop-display photo 24 auto srgb 1.0 1 1; then exit 1; fi
if admin desktop-display photo 24 auto srgb 9.0 0 0; then exit 1; fi
admin desktop-settings pages keyboard escape mono 16 0 auto
admin desktop-status | grep -qx PB626_EPD_MIXED=1
admin desktop-idle 0
admin desktop-taskbar 1 56
admin desktop-status | grep -qx PB626_TASKBAR=1
admin desktop-status | grep -qx PB626_TASKBAR_SIZE=56
if admin desktop-taskbar 2 56; then exit 1; fi
if admin desktop-taskbar 1 99; then exit 1; fi
admin desktop-appearance 56 48
admin desktop-status | grep -qx PB626_PANEL_SIZE=56
admin desktop-status | grep -qx PB626_TITLEBAR_SIZE=48
if admin desktop-appearance 0 48; then exit 1; fi
if admin desktop-appearance 56 99; then exit 1; fi
admin desktop-dpi 144
admin desktop-status | grep -qx PB626_UI_DPI=144
if admin desktop-dpi 0; then exit 1; fi
if admin desktop-dpi '144; bad'; then exit 1; fi
admin desktop-hold 750
admin desktop-status | grep -qx PB626_TASKBAR=1
admin desktop-status | grep -qx PB626_TASKBAR_SIZE=56
admin desktop-status | grep -qx PB626_PANEL_SIZE=56
admin desktop-status | grep -qx PB626_TITLEBAR_SIZE=48
admin desktop-status | grep -qx PB626_BUTTON_HOLD_MS=750
admin desktop-status | grep -qx PB626_UI_DPI=144
admin desktop-status | grep -qx PB626_EPD_MIXED=1
for value in 0 299 3000 0500 bad; do
    if admin desktop-hold "$value"; then exit 1; fi
done
for args in 'frontlight -1' 'frontlight 101' 'frontlight 01' \
    'frontlight 1+2' 'light-on extra' 'light-level 0' 'governor bad' 'power-key bad' 'led bad' 'hostname -bad' 'ntp bad' \
    'desktop-settings pages keyboard menu mono 16 0 bad' 'desktop-settings bad keyboard menu ui 16 0' \
    'desktop-settings pages keyboard menu ui 16 5' 'suspend extra' \
    'manual-time --help 12:00:00' 'manual-time 2026-02-30 12:00:00' \
    'manual-time 2026-02-01 25:00:00' 'timezone --help'; do
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
admin lock-indicator sleep
test "$(cat "$tmp/leds/led/trigger")" = none
test "$(cat "$tmp/leds/led/brightness")" = 0
test "$(cat "$tmp/backlight/panel/bl_power")" = 4
test "$(admin light-status)" = '1 72'
admin lock-indicator awake
test "$(cat "$tmp/leds/led/trigger")" = heartbeat
test "$(cat "$tmp/backlight/panel/bl_power")" = 0
test ! -e "$tmp/indicator"
# A failed frontlight restoration must not skip restoring the LED.
admin lock-indicator sleep
rm "$tmp/backlight/panel/brightness"
mkdir "$tmp/backlight/panel/brightness"
if admin lock-indicator awake; then exit 1; fi
test "$(cat "$tmp/leds/led/trigger")" = heartbeat
test -e "$tmp/indicator"
rmdir "$tmp/backlight/panel/brightness"
touch "$tmp/backlight/panel/brightness"
admin lock-indicator awake
test ! -e "$tmp/indicator"
touch "$tmp/qualified"
admin power-key s2idle
test "$(admin power-key-status)" = s2idle
admin desktop-settings arrows home menu balanced 24 30
admin desktop-status | grep -qx PB626_IDLE_MINUTES=30
test "$(admin button-bindings-status)" = 'Left none none Right none none Home recent-apps none Menu refresh none'
admin button-bindings Page_Up none F1 Page_Down none F2 keyboard recent-apps none Escape refresh light-toggle
test "$(admin button-bindings-status)" = 'Page_Up none F1 Page_Down none F2 keyboard recent-apps none Escape refresh light-toggle'
if admin button-bindings Left none none Right none none Home none none Menu refresh 'sh -c bad'; then exit 1; fi
admin button-bindings-reset
test "$(admin button-bindings-status)" = 'Left none none Right none none Home recent-apps none Menu refresh none'
test "$(admin battery-status)" = '10 3'
admin battery-settings 15 4
test "$(admin battery-status)" = '15 4'
for args in 'battery-settings 4 3' 'battery-settings 5 5' 'battery-settings 31 3' 'battery-settings 10 1'; do
    if admin $args; then echo "Invalid battery policy: $args" >&2; exit 1; fi
done
# Exercise the actual critical-battery transaction without the host's
# power supplies or PID 1. No shutdown on a single sample or a charger.
printf 'Battery\n' >"$tmp/power_supply/battery/type"
printf '1\n' >"$tmp/power_supply/battery/present"
printf 'Discharging\n' >"$tmp/power_supply/battery/status"
printf '4\n' >"$tmp/power_supply/battery/capacity"
printf 'USB\n' >"$tmp/power_supply/usb/type"
printf '0\n' >"$tmp/power_supply/usb/online"
printf '100.00 0.00\n' >"$tmp/uptime"
printf 'ready\n' >"$tmp/run/pb626-desktop/ready"
admin battery-check
grep -Fxq -- '--no-block start pb626-battery-warning.service' "$PB626_TEST_SYSTEMCTL_LOG"
grep -Fxq -- '--no-block start pb626-battery-confirm.timer' "$PB626_TEST_SYSTEMCTL_LOG"
! grep -Fxq -- '--no-block poweroff' "$PB626_TEST_SYSTEMCTL_LOG"
printf '105.00 0.00\n' >"$tmp/uptime"
admin battery-check
! grep -Fxq -- '--no-block poweroff' "$PB626_TEST_SYSTEMCTL_LOG"
printf '1\n' >"$tmp/power_supply/usb/online"
printf '112.00 0.00\n' >"$tmp/uptime"
admin battery-check
test ! -e "$tmp/run/pb626-battery-critical"
! grep -Fxq -- '--no-block poweroff' "$PB626_TEST_SYSTEMCTL_LOG"
# Missing battery presence also fails closed.
printf '0\n' >"$tmp/power_supply/battery/present"
printf '0\n' >"$tmp/power_supply/usb/online"
admin battery-check
test ! -e "$tmp/run/pb626-battery-critical"
printf '1\n' >"$tmp/power_supply/battery/present"
# Missing charger telemetry also fails closed.
rm "$tmp/power_supply/usb/online"
admin battery-check
test ! -e "$tmp/run/pb626-battery-critical"
printf '0\n' >"$tmp/power_supply/usb/online"
admin battery-check
printf '124.00 0.00\n' >"$tmp/uptime"
admin battery-check
grep -Fxq -- '--no-block poweroff' "$PB626_TEST_SYSTEMCTL_LOG"

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
