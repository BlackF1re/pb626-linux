#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

mkdir -p "$fixture/proc/device-tree" \
    "$fixture/proc/bus/input" \
    "$fixture/sys/class/backlight/lcd" \
    "$fixture/sys/class/net/wlan0/wireless" \
    "$fixture/sys/class/power_supply/battery" \
    "$fixture/sys/block/mmcblk0" \
    "$fixture/sys/bus/i2c/devices/0-0024"

printf 'PocketBook Test Board\000' > "$fixture/proc/device-tree/model"
printf 'vendor,board\000allwinner,sun5i-a13\000' > "$fixture/proc/device-tree/compatible"
printf 'Hardware\t: Allwinner sun5i\nSerial\t: PRIVATE-CANARY\n' > "$fixture/proc/cpuinfo"
printf 'MemTotal:         262144 kB\nSwapTotal:             0 kB\n' > "$fixture/proc/meminfo"
printf '   major minor  #blocks  name\n 179        0    4000000 mmcblk0\n' > "$fixture/proc/partitions"
printf 'N: Name="test touchscreen"\nH: Handlers=event0\n' > "$fixture/proc/bus/input/devices"
printf '100\n' > "$fixture/sys/class/backlight/lcd/max_brightness"
printf '85\n' > "$fixture/sys/class/backlight/lcd/brightness"
printf '0\n' > "$fixture/sys/block/mmcblk0/removable"
printf '8000000\n' > "$fixture/sys/block/mmcblk0/size"
printf 'test-touch\n' > "$fixture/sys/bus/i2c/devices/0-0024/name"
printf 'Battery\n' > "$fixture/sys/class/power_supply/battery/type"
printf '81\n' > "$fixture/sys/class/power_supply/battery/capacity"

PB626_PROBE_ROOT="$fixture" sh scripts/probe-device.sh > "$fixture/report"
grep -Fq 'PocketBook Test Board' "$fixture/report"
grep -Fq 'allwinner,sun5i-a13' "$fixture/report"
grep -Fq 'MemTotal:' "$fixture/report"
grep -Fq 'test touchscreen' "$fixture/report"
grep -Fq 'backlight: lcd' "$fixture/report"
grep -Fq 'interface: wlan0' "$fixture/report"
grep -Fq 'test-touch' "$fixture/report"
grep -Fq 'Inventory complete. No changes were made.' "$fixture/report"
if grep -Fq 'PRIVATE-CANARY' "$fixture/report"; then
    printf '%s\n' 'probe leaked a serial number' >&2
    exit 1
fi
sh scripts/probe-device.sh --help | grep -Fq 'Read-only'
printf '%s\n' 'probe smoke test: PASS'
