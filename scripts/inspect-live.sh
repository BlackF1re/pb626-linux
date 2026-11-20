#!/bin/sh
# Read-only diagnostics for FEL-booted Alpine. Review output before sharing.
set -u
printf '%s\n' '== Kernel / command line =='
uname -r
cat /proc/cmdline 2>/dev/null || true
printf '\n%s\n' '== Root / MMC =='
awk '$2 == "/" {print $1, $2, $3, $4}' /proc/mounts
for dir in /sys/class/mmc_host/mmc*; do [ -d "$dir" ] && echo "MMC host: $dir"; done
printf '\n%s\n' '== E Ink nodes =='
for dev in /dev/eink-panel /dev/fb* /dev/video*; do [ ! -e "$dev" ] || ls -l "$dev"; done
printf '\n%s\n' '== Relevant modules =='
awk '/eink|sunxi|tps65185|pwm|backlight|rtl8xxxu|r8188eu|cyttsp|elan|edt_ft|usb_f_acm/ {print $1, $3}' /proc/modules 2>/dev/null || true
printf '\n%s\n' '== Backlight state =='
for dev in /sys/class/backlight/*; do
    [ -d "$dev" ] || continue
    echo "$dev"
    for field in brightness actual_brightness max_brightness bl_power; do
        if [ -r "$dev/$field" ]; then printf '%s=' "$field"; cat "$dev/$field"; fi
    done
done
printf '\n%s\n' '== PWM state (read-only) =='
for dev in /sys/class/pwm/pwmchip*; do
    [ -d "$dev" ] || continue
    echo "$dev"
    for p in "$dev"/pwm*; do
        [ -d "$p" ] || continue
        for field in enable period duty_cycle polarity; do
            if [ -r "$p/$field" ]; then printf '%s/%s=' "$p" "$field"; cat "$p/$field"; fi
        done
    done
done
printf '\n%s\n' '== Relevant kernel messages (may contain device details) =='
dmesg 2>/dev/null | grep -Ei 'eink|tps65185|backlight|pwm|mmc0|mmc2|ext4|elan|cypress' | tail -n 70 || true

printf '\n%s\n' '== Device tree / touchscreen =='
for name in /sys/bus/i2c/devices/2-0015 /sys/bus/i2c/devices/2-0024; do
    [ ! -d "$name" ] || {
        printf '%s: ' "$name"
        if [ -L "$name/driver" ]; then readlink "$name/driver"; else echo 'no driver'; fi
    }
done
for path in /sys/class/input/event*/device/name; do
    [ -r "$path" ] || continue
    printf '%s: ' "$path"
    cat "$path"
done
printf '\n%s\n' '== Wi-Fi / USB host (no MAC addresses) =='
for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ] || continue
    printf '%s VID:PID ' "$dev"
    cat "$dev/idVendor" "$dev/idProduct" | tr '\n' ':'
    printf '\n'
done
for dev in /sys/class/net/*; do
    [ -d "$dev/wireless" ] && printf 'wireless interface: %s\n' "${dev##*/}"
done
printf '\n%s\n' '== RTC and system power =='
for dev in /sys/class/rtc/rtc*; do
    [ -d "$dev" ] || continue
    printf '%s ' "$dev"
    [ ! -r "$dev/name" ] || cat "$dev/name"
done
for dev in /sys/class/power_supply/*; do
    [ -d "$dev" ] || continue
    echo "$dev"
    for field in type status online capacity; do
        if [ -r "$dev/$field" ]; then
            printf '  %s=' "$field"
            cat "$dev/$field"
        fi
    done
done
printf '\n%s\n' '== eMMC safety =='
for dev in /sys/block/mmcblk*; do
    [ -r "$dev/device/type" ] || continue
    printf '%s: %s\n' "$dev" "$(cat "$dev/device/type")"
done
