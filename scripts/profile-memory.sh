#!/bin/sh
# Read-only diagnostics, no resident process or extra dependencies.
set -eu
printf 'Kernel: '; uname -r
printf '\nMemory (KiB):\n'
grep -E '^(MemTotal|MemFree|MemAvailable|Cached|Shmem|Slab|SReclaimable|SUnreclaim|KernelStack|PageTables|CmaTotal|CmaFree|SwapTotal|SwapFree):' /proc/meminfo
printf '\nProcess PSS (KiB, root sees all processes):\n'
for p in /proc/[0-9]*; do
    [ -r "$p/smaps_rollup" ] || continue
    name=$(cat "$p/comm" 2>/dev/null) || continue
    pss=$(awk '/^Pss:/ {print $2}' "$p/smaps_rollup" 2>/dev/null) || continue
    [ -z "$pss" ] || printf '%s %s %s\n' "$pss" "${p##*/}" "$name"
done | sort -nr
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
