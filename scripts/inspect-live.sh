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
awk '/eink|sunxi|tps65185|pwm|backlight|rtl8xxxu/ {print $1, $3}' /proc/modules 2>/dev/null || true
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
