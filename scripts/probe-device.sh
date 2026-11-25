#!/bin/sh
# Read-only hardware inventory for PocketBook 626/626 Plus.
set -u
LC_ALL=C
export LC_ALL

case "${1:-}" in
    "" ) ;;
    -h|--help)
        printf '%s\n' 'Usage: sh probe-device.sh > pocketbook-hardware.txt'             'Read-only. Does not collect MAC addresses, storage IDs or kernel logs.'
        exit 0
        ;;
    *)
        printf '%s\n' 'Unexpected argument. Use --help.' >&2
        exit 2
        ;;
esac

ROOT=${PB626_PROBE_ROOT:-}
if [ -n "$ROOT" ] && [ ! -d "$ROOT/proc" ]; then
    printf '%s\n' 'PB626_PROBE_ROOT must contain a proc directory.' >&2
    exit 2
fi

section() {
    printf '\n== %s ==\n' "$1"
}

field() {
    label=$1
    file=$2
    if [ -r "$file" ] && [ -f "$file" ]; then
        printf '%s: ' "$label"
        tr '\n' ' ' < "$file"
        printf '\n'
    fi
}

section 'Kernel'
if [ -z "$ROOT" ]; then
    uname -s -r -m 2>/dev/null || :
else
    printf '%s\n' '(fixture root)'
fi
if [ -r "$ROOT/proc/version" ]; then
    field 'Version' "$ROOT/proc/version"
fi

section 'Board'
if [ -r "$ROOT/proc/device-tree/model" ]; then
    printf 'Model: '
    tr '\000' '\n' < "$ROOT/proc/device-tree/model"
elif [ -r "$ROOT/sys/firmware/devicetree/base/model" ]; then
    printf 'Model: '
    tr '\000' '\n' < "$ROOT/sys/firmware/devicetree/base/model"
fi
if [ -r "$ROOT/proc/device-tree/compatible" ]; then
    printf '%s\n' 'Compatible:'
    tr '\000' '\n' < "$ROOT/proc/device-tree/compatible"
elif [ -r "$ROOT/sys/firmware/devicetree/base/compatible" ]; then
    printf '%s\n' 'Compatible:'
    tr '\000' '\n' < "$ROOT/sys/firmware/devicetree/base/compatible"
fi
if [ -r "$ROOT/proc/cpuinfo" ]; then
    grep -E '^(Processor|Hardware|Revision|CPU architecture|model name|Features)[[:space:]]*:'         "$ROOT/proc/cpuinfo" || :
fi
if [ -r "$ROOT/proc/meminfo" ]; then
    grep -E '^(MemTotal|SwapTotal):' "$ROOT/proc/meminfo" || :
fi

section 'Storage layout (no identifiers)'
if [ -r "$ROOT/proc/mtd" ]; then
    cat "$ROOT/proc/mtd"
fi
if [ -r "$ROOT/proc/partitions" ]; then
    cat "$ROOT/proc/partitions"
fi
for dev in "$ROOT"/sys/block/mmcblk* "$ROOT"/sys/block/mtdblock* "$ROOT"/sys/block/nand*; do
    [ -d "$dev" ] || continue
    printf 'block: %s\n' "${dev##*/}"
    field '  removable' "$dev/removable"
    field '  sectors' "$dev/size"
    field '  type' "$dev/device/type"
    field '  model' "$dev/device/name"
done

section 'Display and backlight'
for fb in "$ROOT"/sys/class/graphics/fb*; do
    [ -d "$fb" ] || continue
    printf 'framebuffer: %s\n' "${fb##*/}"
    field '  name' "$fb/name"
    field '  virtual size' "$fb/virtual_size"
    field '  bits per pixel' "$fb/bits_per_pixel"
done
for light in "$ROOT"/sys/class/backlight/*; do
    [ -d "$light" ] || continue
    printf 'backlight: %s\n' "${light##*/}"
    field '  max brightness' "$light/max_brightness"
    field '  brightness' "$light/brightness"
done

section 'Input devices'
if [ -r "$ROOT/proc/bus/input/devices" ]; then
    grep -E '^(N|H):' "$ROOT/proc/bus/input/devices" || :
fi

section 'I2C devices'
for name in "$ROOT"/sys/bus/i2c/devices/*/name; do
    [ -r "$name" ] || continue
    printf '%s: ' "${name%/name}"
    tr '\n' ' ' < "$name"
    printf '\n'
done

section 'SPI devices'
for dev in "$ROOT"/sys/bus/spi/devices/*; do
    [ -d "$dev" ] || continue
    printf 'spi: %s\n' "${dev##*/}"
done

section 'Network interfaces (no addresses)'
for net in "$ROOT"/sys/class/net/*; do
    [ -d "$net" ] || continue
    printf 'interface: %s\n' "${net##*/}"
    if [ -d "$net/wireless" ] || [ -e "$net/phy80211" ]; then
        printf '%s\n' '  wireless: yes'
    fi
    if [ -L "$net/device/driver" ]; then
        driver=$(readlink "$net/device/driver" 2>/dev/null || :)
        printf '  driver: %s\n' "${driver##*/}"
    fi
done

section 'Power supplies'
for supply in "$ROOT"/sys/class/power_supply/*; do
    [ -d "$supply" ] || continue
    printf 'supply: %s\n' "${supply##*/}"
    field '  type' "$supply/type"
    field '  status' "$supply/status"
    field '  online' "$supply/online"
    field '  capacity' "$supply/capacity"
done

section 'Device nodes'
for node in dev/fb0 dev/eink-panel dev/input/event0 dev/mmcblk0 dev/mtd0; do
    if [ -e "$ROOT/$node" ]; then
        printf 'present: /%s\n' "$node"
    fi
done

printf '\n%s\n' 'Inventory complete. No changes were made.'
