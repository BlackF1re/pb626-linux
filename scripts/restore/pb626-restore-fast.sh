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

# Resolve only the physical external MMC0 host, never a device supplied by
# the PC or a numbered node which might refer to the internal eMMC.
sd_device() {
    test -e "$chosen/pb626,sd-backup" || fail "SD recovery profile required"
    set -- /sys/bus/mmc/devices/mmc0:*/block/mmcblk*
    test "$#" = 1 && test -d "$1" || fail "Expected exactly one SD card on MMC0"
    sd_sys=$1
    sd_path=/dev/${sd_sys##*/}
    test -b "$sd_path" || fail "SD block node missing"
    test "$(cat "$sd_sys/device/type")" = SD || fail "Not an SD card"
    test "$(cat "$sd_sys/removable")" = 1 || fail "SD is not removable"
    test "$(blockdev --getss "$sd_path")" = 512 || fail "Unexpected SD sector size"
    sd_cid=$(cat "$sd_sys/device/cid")
    test "${#sd_cid}" = 32 || fail "Invalid SD CID"
    case "$sd_cid" in *[!0-9a-f]*) fail "Invalid SD CID" ;; esac
    sd_sectors=$(blockdev --getsz "$sd_path")
    number "$sd_sectors"
    test "$sd_sectors" -gt 0 && test "$sd_sectors" -le 2147483648 || fail "Unsupported SD capacity"
    unmounted
}

sd_info() {
    sd_device
    for node in "$sd_path" "$sd_path"p[0-9]*; do
        test -b "$node" || continue
        blockdev --setro "$node"
        test "$(blockdev --getro "$node")" = 1 || fail "SD lock failed"
    done
    printf 'CID=%s\nSECTORS=%s\n' "$sd_cid" "$sd_sectors"
}

sd_identity() {
    sd_device
    test "${PB626_SD_CID:-}" = "$sd_cid" || fail "SD CID changed or not selected"
    test "${PB626_SD_SECTORS:-}" = "$sd_sectors" || fail "SD size changed or not selected"
}

select_region() {
    tail=$chunk
    case "$1" in
        user) device=$disk; blocks=1864; force_ro= ;;
        boot0|boot1) device=$disk$1; blocks=1; force_ro=$sys$1/force_ro ;;
        sd)
            sd_identity
            device=$sd_path
            blocks=$(((sd_sectors+8191)/8192))
            tail=$(((sd_sectors-(blocks-1)*8192)*512))
            force_ro=
            ;;
        *) fail "Unknown region" ;;
    esac
}

block_length() {
    length=$chunk
    if test "$1" -eq "$((blocks-1))"; then length=$tail; fi
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
    test "$(wc -c <"$data")" -eq "${length:-$chunk}" || fail "Unexpected chunk length"
    check_hash "$data"
}

operation=$1
shift
# RAM recovery exposes ACM even if storage is damaged. Never mistake that
# diagnostic shell for an authorized block-transfer session.
if test -r /etc/pb626-image-id && grep -qx pb626-debian13-recovery-v1 /etc/pb626-image-id &&
   test "${PB626_STORAGE_INIT:-}" != 1; then
    ready=
    case "$operation:${1:-}" in
        sd-info:*|sd-test-disk:*|*:sd) ready=/run/pb626-sd-ready ;;
        probe:*|backup-info:*|test-disk:*|backup-read:*|backup-read-packed:*|backup-hash:*|scan:*|verify:*|write:*)
            ready=/run/pb626-emmc-ready ;;
    esac
    if test -n "$ready"; then
        # The host may open ACM while the boot-time storage check is still
        # in progress. This is a bounded readiness wait, not a retry of I/O.
        for attempt in $(seq 1 35); do
            test ! -e "$ready" || break
            sleep 1
        done
        test -e "$ready" || fail "Storage recovery not ready: $ready"
    fi
fi
case "$operation" in
    probe) probe ;;
    sd-info) sd_info ;;
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
        block_length "$2"
        unmounted
        test "$(blockdev --getro "$device")" = 1 || fail "$device is writable"
        work=$(mktemp -d /run/pb626-fast.XXXXXX)
        tty_settings=
        unlocked=0
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        dd if="$device" of="$work/chunk" bs="$chunk" skip="$2" count=1 status=none
        test "$(wc -c <"$work/chunk")" -eq "$length" || fail "Short read"
        digest=$(sha256sum "$work/chunk")
        format=raw
        payload=$work/chunk
        bytes=$length
        if test "$operation" = backup-read-packed; then
            # The hash is of four MiB of zero bytes, not of an empty file.
            if test "$length" = "$chunk" && test "${digest%% *}" = bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8; then
                format=zero
                bytes=0
            elif gzip -c "$work/chunk" >"$work/packed"; then
                packed=$(wc -c <"$work/packed")
                if test "$packed" -lt "$((length-65536))"; then
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
            printf '\nPB626_DATA %s %s\n' "$length" "${digest%% *}"
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
    sd-test-disk)
        select_region sd
        test "$(blockdev --getro "$device")" = 1 || fail "SD is writable"
        block_length 0
        exec "$scanner" scan "$device" 1 "$length"
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
        if test "$1" = sd; then
            exec "$scanner" "$operation" "$device" "$blocks" "$tail"
        fi
        exec "$scanner" "$operation" "$device" "$blocks"
        ;;
    write)
        select_region "$1"
        number "$2"
        test "$2" -lt "$blocks" || fail "Block index outside region"
        block_length "$2"
        receive "$4" "$5"
        decode_chunk "$3"
        if test "$1" = sd; then
            sd_identity
            test "$device" = "$sd_path" || fail "SD path changed"
        fi
        unmounted
        test "$(blockdev --getro "$device")" = 1 || fail "$device is writable"
        unlocked=1
        if test -n "$force_ro"; then printf 0 >"$force_ro"; fi
        blockdev --setrw "$device"
        dd if="$data" of="$device" bs="$chunk" seek="$2" conv=notrunc status=none
        sync
        lock_region || fail "Failed to relock $device"
        unlocked=0
        if test "$1" = sd; then sd_identity; fi
        ;;
    *) fail "Unknown operation" ;;
esac
