#!/bin/sh
# Read-only diagnostics, no resident process or extra dependencies.
set -eu
printf 'Kernel: '; uname -r
printf '\nMemory (KiB):\n'
grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|AnonPages|Mapped|Shmem|Slab|SReclaimable|SUnreclaim|KernelStack|PageTables|CmaTotal|CmaFree|SwapTotal|SwapFree|Unevictable|Mlocked|VmallocUsed):' /proc/meminfo
printf '\nProcess PSS (KiB, root sees all processes):\n'
for p in /proc/[0-9]*; do
    [ -r "$p/smaps_rollup" ] || continue
    name=$(cat "$p/comm" 2>/dev/null) || continue
    pss=$(awk '/^Pss:/ {print $2}' "$p/smaps_rollup" 2>/dev/null) || continue
    [ -z "$pss" ] || printf '%s %s %s\n' "$pss" "${p##*/}" "$name"
done | sort -nr
printf '\nMemory reclaim counters (cumulative):\n'
grep -E '^(pgmajfault|pswpin|pswpout|pgscan_[^ ]+|pgsteal_[^ ]+|allocstall[^ ]*|compact_[^ ]+|oom_kill) ' /proc/vmstat || :
printf '\nMemory policy:\n'
for field in swappiness page-cluster; do
    printf '%s=' "$field"
    cat "/proc/sys/vm/$field"
done
if [ -r /sys/kernel/mm/lru_gen/enabled ]; then
    printf 'lru_gen='
    cat /sys/kernel/mm/lru_gen/enabled
fi
printf '\nLoaded modules:\n'
cat /proc/modules
printf '\nZram mm_stat:\n'
cat /sys/block/zram0/mm_stat 2>/dev/null || :
for pressure in cpu memory io; do
    printf '\nPSI %s:\n' "$pressure"
    cat "/proc/pressure/$pressure" 2>/dev/null || :
done

# Optional cgroup v2 diagnostics: no writes and no background monitoring.
for group in /sys/fs/cgroup/pb626.slice /sys/fs/cgroup/pb626.slice/pb626-desktop.service /sys/fs/cgroup/pb626.slice/pb626-renderer-*.scope; do
    [ -d "$group" ] || continue
    printf '\nCgroup %s:\n' "${group##*/}"
    for field in memory.current memory.low memory.events memory.pressure cpu.weight cpu.pressure io.pressure; do
        [ -r "$group/$field" ] || continue
        printf '%s:\n' "$field"
        cat "$group/$field" 2>/dev/null || :
    done
done

# Read-only device PM telemetry in the same report; do not wake devices
# with raw I2C/USB accesses. sysfs battery samples may be instantaneous.
printf '\nPower supplies (kernel units: uA, uV, uAh, uWh):\n'
for supply in /sys/class/power_supply/*; do
    [ -d "$supply" ] || continue
    printf '%s:\n' "${supply##*/}"
    for field in type present online status capacity voltage_now current_now power_now charge_now energy_now; do
        [ -r "$supply/$field" ] || continue
        value=$(cat "$supply/$field" 2>/dev/null) || continue
        printf '  %s=%s\n' "$field" "$value"
    done
done
printf '\nSystem sleep capabilities:\n'
for field in state mem_sleep pm_test wakeup_count; do
    [ -r "/sys/power/$field" ] || continue
    printf '%s=' "$field"
    cat "/sys/power/$field" 2>/dev/null || :
done
printf '\nCPU idle counters (microseconds):\n'
for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    [ -d "$state" ] || continue
    printf '%s:\n' "${state##*/}"
    for field in name latency residency usage time disable; do
        [ -r "$state/$field" ] || continue
        printf '  %s=' "$field"
        cat "$state/$field" 2>/dev/null || :
    done
done
printf '\nE-Ink and USB power management (no serial numbers or network addresses):\n'
for dev in /sys/class/video4linux/video0/device /sys/bus/usb/devices/*; do
    [ -d "$dev/power" ] || continue
    if [ -r "$dev/idVendor" ] && [ -r "$dev/idProduct" ]; then
        printf 'usb %s:%s (%s):\n' "$(cat "$dev/idVendor")" "$(cat "$dev/idProduct")" "${dev##*/}"
    elif [ "$dev" = /sys/class/video4linux/video0/device ]; then
        printf 'E-Ink video0:\n'
    else
        continue
    fi
    for field in control runtime_status runtime_active_time runtime_suspended_time autosuspend_delay_ms wakeup; do
        [ -r "$dev/power/$field" ] || continue
        value=$(cat "$dev/power/$field" 2>/dev/null) || continue
        printf '  %s=%s\n' "$field" "$value"
    done
done
