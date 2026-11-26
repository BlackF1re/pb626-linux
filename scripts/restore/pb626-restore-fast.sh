#!/bin/sh
set -eu

disk=/dev/mmcblk2
sys=/sys/class/block/mmcblk2
chosen=/sys/firmware/devicetree/base/chosen
scanner=/run/pb626-restore-scan
chunk=4194304

fail() { echo "$*" >&2; exit 1; }

unmounted() {
    awk '$1 ~ /\/mmcblk/ { bad=1 } END { exit bad }' /proc/mounts /proc/swaps ||
        fail "An MMC device is in use"
}

probe() {
    test -f "$chosen/pb626,emmc-backup" || fail "Wrong RAM boot variant"
    compatible=${chosen%/chosen}/soc/i2c@1c2b400/touchscreen@15/compatible
    tr '\000' '\n' <"$compatible" | grep -qx elan,ektf2227 || fail "Wrong board variant"
    test "$(cat "$sys/device/name")" = 8WPD3R || fail "Unexpected eMMC model"
    test "$(cat "$sys/removable")" = 0 || fail "Target is removable"
    test "$(blockdev --getss "$disk")" = 512 || fail "Unexpected sector size"
    test "$(blockdev --getsz "$disk")" = 15269888 || fail "Unexpected user area size"
    for region in boot0 boot1; do
        test "$(blockdev --getsz "$disk$region")" = 8192 || fail "Unexpected boot area size"
        test "$(cat "$sys$region/force_ro")" = 1 || fail "Boot area is not locked"
    done
    for node in "$disk" "$disk"boot[01] "$disk"p[0-9]*; do
        test -b "$node" || continue
        test "$(blockdev --getro "$node")" = 1 || fail "$node is writable"
    done
    unmounted

    card=$(basename "$(readlink "$sys/device")")
    ext=/sys/kernel/debug/mmc2/$card/ext_csd
    if ! test -r "$ext"; then
        mount -t debugfs debugfs /sys/kernel/debug
    fi
    test "$(dd if="$ext" bs=1 skip=358 count=2 status=none)" = 00 ||
        fail "Unexpected PARTITION_CONFIG"
    test "$(dd if="$ext" bs=1 skip=286 count=24 status=none)" = 000000000000000000000000 ||
        fail "General-purpose partitions are configured"
    printf 'CID=%s\n' "$(cat "$sys/device/cid")"
}

select_region() {
    case "$1" in
        user) device=$disk; blocks=1864; force_ro= ;;
        boot0|boot1) device=$disk$1; blocks=1; force_ro=$sys$1/force_ro ;;
        *) fail "Unknown region" ;;
    esac
}

number() {
    case "$1" in ''|*[!0-9]*) fail "Invalid numeric argument" ;; esac
}

lock_region() {
    if test -n "$force_ro"; then printf 1 >"$force_ro" || return 1; fi
    blockdev --setro "$device" && test "$(blockdev --getro "$device")" = 1
}

receive() {
    bytes=$1
    expected_hash=$2
    number "$bytes"
    test "$bytes" -gt 0 && test "$bytes" -le "$chunk" || fail "Invalid payload length"
    work=$(mktemp -d /run/pb626-fast.XXXXXX)
    tty_settings=
    unlocked=0
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM

    tty_settings=$(stty -g)
    stty raw -echo
    printf '\nPB626_READY\n'
    timeout 90 head -c "$bytes" >"$work/payload"
    stty "$tty_settings"
    tty_settings=
    test "$(wc -c <"$work/payload")" -eq "$bytes" || fail "Short USB transfer"
}

cleanup() {
    status=$?
    trap - EXIT
    if test "$unlocked" = 1; then lock_region || status=1; fi
    if test -n "$tty_settings"; then stty "$tty_settings" || status=1; fi
    rm -rf "$work"
    exit "$status"
}

check_hash() {
    actual=$(sha256sum "$1")
    test "${actual%% *}" = "$expected_hash" || fail "Payload SHA-256 mismatch"
}

decode_chunk() {
    case "$1" in
        raw) data=$work/payload ;;
        gzip)
            data=$work/chunk
            # Bound decompression even if the input was corrupted.
            (ulimit -f 8192; gzip -dc "$work/payload" >"$data")
            ;;
        *) fail "Unknown compression" ;;
    esac
    test "$(wc -c <"$data")" -eq "$chunk" || fail "Unexpected chunk length"
    check_hash "$data"
}

operation=$1
shift
case "$operation" in
    probe) probe ;;
    backup-info)
        probe
        card=$(basename "$(readlink "$sys/device")")
        ext=/sys/kernel/debug/mmc2/$card/ext_csd
        hex=$(tr -d '\r\n ' < "$ext")
        test "${#hex}" -eq 1024 || fail "Unexpected EXT_CSD length"
        case "$hex" in *[!0-9a-fA-F]*) fail "Invalid EXT_CSD" ;; esac
        printf 'EXT_CSD=%s\n' "$hex"
        ;;
    backup-read|backup-read-packed)
        select_region "$1"
        number "$2"
        test "$2" -lt "$blocks" || fail "Block index outside region"
        unmounted
        test "$(blockdev --getro "$device")" = 1 || fail "$device is writable"
        work=$(mktemp -d /run/pb626-fast.XXXXXX)
        tty_settings=
        unlocked=0
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        dd if="$device" of="$work/chunk" bs="$chunk" skip="$2" count=1 status=none
        test "$(wc -c <"$work/chunk")" -eq "$chunk" || fail "Short read"
        digest=$(sha256sum "$work/chunk")
        format=raw
        payload=$work/chunk
        bytes=$chunk
        if test "$operation" = backup-read-packed; then
            # The hash is of four MiB of zero bytes, not of an empty file.
            if test "${digest%% *}" = bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8; then
                format=zero
                bytes=0
            elif gzip -c "$work/chunk" >"$work/packed"; then
                packed=$(wc -c <"$work/packed")
                if test "$packed" -lt "$((chunk-65536))"; then
                    format=gzip
                    payload=$work/packed
                    bytes=$packed
                fi
            fi
        fi
        tty_settings=$(stty -g)
        stty raw -echo
        if test "$operation" = backup-read-packed; then
            printf '\nPB626_DATA %s %s %s\n' "$bytes" "${digest%% *}" "$format"
        else
            printf '\nPB626_DATA %s %s\n' "$chunk" "${digest%% *}"
        fi
        test "$bytes" = 0 || cat "$payload"
        stty "$tty_settings"
        tty_settings=
        printf '\nPB626_DATA_END\n'
        ;;
    backup-hash)
        select_region "$1"
        unmounted
        test "$(blockdev --getro "$device")" = 1 || fail "$device is writable"
        blockdev --flushbufs "$device"
        digest=$(sha256sum "$device")
        printf 'SHA256 %s\n' "${digest%% *}"
        ;;
    load-scanner)
        receive "$1" "$2"
        check_hash "$work/payload"
        gzip -dc "$work/payload" >"$work/scanner"
        chmod 700 "$work/scanner"
        mv -f "$work/scanner" "$scanner"
        ;;
    test-transfer)
        receive "$1" "$2"
        decode_chunk raw
        "$scanner" scan "$data" 1
        ;;
    test-disk)
        test "$(blockdev --getro "$disk")" = 1 || fail "$disk is writable"
        exec "$scanner" scan "$disk" 1
        ;;
    scan|verify)
        select_region "$1"
        unmounted
        test "$(blockdev --getro "$device")" = 1 || fail "$device is writable"
        if test "$operation" = verify; then blockdev --flushbufs "$device"; fi
        exec "$scanner" "$operation" "$device" "$blocks"
        ;;
    write)
        select_region "$1"
        number "$2"
        test "$2" -lt "$blocks" || fail "Block index outside region"
        receive "$4" "$5"
        decode_chunk "$3"
        unmounted
        test "$(blockdev --getro "$device")" = 1 || fail "$device is writable"
        unlocked=1
        if test -n "$force_ro"; then printf 0 >"$force_ro"; fi
        blockdev --setrw "$device"
        dd if="$data" of="$device" bs="$chunk" seek="$2" conv=notrunc status=none
        sync
        lock_region || fail "Failed to relock $device"
        unlocked=0
        ;;
    *) fail "Unknown operation" ;;
esac
