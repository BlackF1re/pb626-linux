#!/bin/sh
# Direct artifact installation, restricted to the qualified board and p1,
# native raw kernel, tested BT0. No backup/restore operations here.
set -eu
D=/dev/mmcblk2
P=/dev/mmcblk2p1
S=/sys/class/block/mmcblk2
data_dir=/run/pb626-install-data
mnt=/run/pb626-install-root
fail() { echo "$*" >&2; exit 1; }
number() { case "$1" in ''|*[!0-9]*) fail "Invalid number";; esac; }
identity() {
    test -e /run/pb626-emmc-ready
    test "$(cat "$S/device/name")" = 8WPD3R
    test "$(cat "$S/device/cid")" = "$cid"
    test "$(cat /sys/class/block/mmcblk2p1/start)" = 1009664
    test "$(cat /sys/class/block/mmcblk2p1/size)" = 14260224
    test "$(blockdev --getss "$D")" = 512
    test "$(blockdev --getsz "$D")" = 15269888
    test "$(blockdev --getro "$D")" = 1
    test "$(blockdev --getro "$P")" = 1
    for node in "$D"boot0 "$D"boot1; do
        test "$(blockdev --getro "$node")" = 1
        test "$(cat "$S${node##*mmcblk2}/force_ro")" = 1
    done
    awk '$1 ~ /\/mmcblk/ {bad=1} END {exit bad}' /proc/mounts /proc/swaps
}
lock() {
    blockdev --setro "$P" && blockdev --setro "$D" &&
    test "$(blockdev --getro "$P")" = 1 && test "$(blockdev --getro "$D")" = 1
}
work=
tty_settings=
unlocked=0
mounted=0
cleanup() {
    status=$?
    trap - EXIT
    if test "$mounted" = 1; then sync; busybox umount "$mnt" || status=1; fi
    if test "$unlocked" = 1; then lock || status=1; fi
    if test -n "$tty_settings"; then stty "$tty_settings" || status=1; fi
    if test -n "$work"; then rm -rf "$work"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
operation=$1; cid=$2; shift 2
identity
receive() {
    bytes=$1; expected=$2
    number "$bytes"
    test "$bytes" -gt 0 && test "$bytes" -le 4194304 || fail "Invalid payload length"
    case "$expected" in *[!0-9a-f]*) fail "Invalid hash";; esac
    test "$(printf %s "$expected" | wc -c)" = 64
    work=$(mktemp -d /run/pb626-install.XXXXXX)
    if test "${PB626_TCP:-}" != 1; then
        tty_settings=$(stty -g); stty raw -echo
        printf '\nPB626_READY\n'
    fi
    timeout 90 head -c "$bytes" >"$work/payload"
    if test -n "$tty_settings"; then stty "$tty_settings"; tty_settings=; fi
    test "$(wc -c <"$work/payload")" = "$bytes"
}
check_hash() { printf '%s  %s\n' "$2" "$1" | sha256sum -c -; }
case "$operation" in
    write)
        kind=$1; idx=$2; format=$3; bytes=$4; expected=$5; length=$6
        number "$idx"; number "$length"
        test "$length" -gt 0 && test "$length" -le 4194304 && test $((length%512)) = 0 || fail "Invalid write length"
        case "$kind" in
            rootfs) dev=$P; bs=4194304; seek=$idx; count=1
                test "$idx" -lt 1741
                if test "$idx" = 1740; then test "$length" = 3145728; else test "$length" = 4194304; fi ;;
            kernel) dev=$D; bs=512; seek=$((80+idx*8192)); count=$((length/512))
                test "$idx" -le 2; test $((seek+count)) -le 16465
                if test "$idx" = 2; then test "$length" = 512; fi ;;
            spl) dev=$D; bs=512; seek=16; count=48
                test "$idx" = 0 && test "$length" = 24576 || fail "Invalid BT0 extent"
                test "$expected" = 1da6d425de2f17d65c0b2f0fd9e33245f6662c551773b367a28f9c60e404a3d6 ;;
            *) fail "Invalid write region";;
        esac
        receive "$bytes" "$expected"
        case "$format" in
            raw) data=$work/payload;;
            gzip) data=$work/data; (ulimit -f 8192; gzip -dc "$work/payload" >"$data");;
            *) fail "Invalid encoding";;
        esac
        test "$(wc -c <"$data")" = "$length"
        check_hash "$data" "$expected"
        identity
        unlocked=1
        blockdev --setrw "$D"
        if test "$dev" = "$P"; then blockdev --setrw "$P"; fi
        dd if="$data" of="$dev" bs="$bs" seek="$seek" conv=notrunc,fsync status=none
        lock; unlocked=0
        blockdev --flushbufs "$dev"
        dd if="$dev" of="$work/readback" bs="$bs" skip="$seek" count="$count" status=none
        test "$(wc -c <"$work/readback")" = "$length"
        check_hash "$work/readback" "$expected"
        printf '\nPB626_WRITTEN\n'
        ;;
    reset-data)
        rm -rf "$data_dir"; mkdir -m 700 "$data_dir"
        ;;
    file)
        name=$1; offset=$2; bytes=$3; expected=$4
        case "$name" in default.wbf|password|sleep-portrait.pb|sleep-landscape.pb) ;; *) fail "Invalid personalization file";; esac
        number "$offset"; number "$bytes"
        test "$bytes" -le 1048576
        test $((offset+bytes)) -le 16777216
        test -d "$data_dir"
        path=$data_dir/$name
        if test "$offset" = 0; then
            test ! -e "$path"; (umask 077; : >"$path")
        fi
        test "$(wc -c <"$path")" = "$offset"
        receive "$bytes" "$expected"
        check_hash "$work/payload" "$expected"
        cat "$work/payload" >>"$path"
        test "$(wc -c <"$path")" = "$((offset+bytes))"
        ;;
    check-data|personalize)
        check_hash "$data_dir/default.wbf" bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f
        check_hash "$data_dir/sleep-portrait.pb" 5d29e88e4209e7740a4acf7b9a77eb6097df23a6c3bd896168e4788c715223d8
        check_hash "$data_dir/sleep-landscape.pb" ac2519eeb2d46aef1e5c724ad8ace66174f4a7fb9432b5bb67ac798facad2d33
        password=$(cat "$data_dir/password")
        printf '%s\n' "$password" | grep -Eq '^\$6\$[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}$'
        if test "$operation" = check-data; then echo PB626_DATA_VERIFIED; exit 0; fi
        mkdir -p "$mnt"
        unlocked=1
        blockdev --setrw "$D"; blockdev --setrw "$P"
        mount -t ext4 -o rw "$P" "$mnt"; mounted=1
        grep -qx pb626-native-debian13-armhf-v1 "$mnt/etc/pb626-image-id"
        shadow=$mnt/etc/shadow
        awk -F: '$1=="root" && $2 ~ /^[!*]/ {n++} END {exit n!=1}' "$shadow"
        cp -p "$shadow" "$shadow.pb626-new"
        awk -F: -v OFS=: -v p="$password" '$1=="root" {$2=p} {print}' "$shadow" >"$shadow.pb626-new"
        mv -f "$shadow.pb626-new" "$shadow"
        awk -F: -v p="$password" '$1=="root" && $2==p {n++} END {exit n!=1}' "$shadow"
        firmware=$mnt/lib/firmware/pb626
        mkdir -p "$firmware"
        for name in default.wbf sleep-portrait.pb sleep-landscape.pb; do
            cp "$data_dir/$name" "$firmware/$name"
            chmod 644 "$firmware/$name"
            hash=$(sha256sum "$data_dir/$name")
            check_hash "$firmware/$name" "${hash%% *}"
        done
        sync
        busybox umount "$mnt"; mounted=0
        lock; unlocked=0
        rm -rf "$data_dir"
        printf '\nPB626_PERSONALIZED\n'
        ;;
    *) fail "Unknown direct-install operation";;
esac
