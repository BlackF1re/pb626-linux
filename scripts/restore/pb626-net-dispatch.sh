#!/bin/sh
# Fixed verbs; never execute a command string supplied by the peer.
set -eu
D=/usr/libexec/pb626-install-direct.sh
R=/usr/libexec/pb626-restore-fast.sh
fail() { echo "$*" >&2; exit 1; }
number() { case "$1" in ''|*[!0-9]*) fail 'Invalid number';; esac; }
cid_check() {
    test "${#1}" = 32 || fail 'Invalid CID'
    case "$1" in *[!0-9a-f]*) fail 'Invalid CID';; esac
}
ready() {
    test -e /run/pb626-emmc-ready || fail 'Storage not ready'
}
# The daemon handles only one connection at a time. Do not use legacy
# emergency writes concurrently with the network service.
case "$1" in
    hello)
        test "$#" = 1
        printf 'PB626-NCM-1\n'
        ;;
    identity)
        test "$#" = 1
        test -f /etc/pb626-windows-build
        cat /etc/pb626-windows-build
        ;;
    test)
        test "$#" = 2
        work=$(mktemp /run/pb626-net-test.XXXXXX)
        trap 'rm -f "$work"' EXIT
        timeout 30 head -c 4194304 >"$work"
        test "$(wc -c <"$work")" = 4194304
        printf '%s  %s\n' "$2" "$work" | sha256sum -c - >/dev/null
        echo TRANSFER_OK
        ;;
    probe)
        test "$#" = 1
        /bin/sh "$R" probe
        ;;
    layout)
        test "$#" = 1
        ready
        for p in 1 2 8; do
            node=/sys/class/block/mmcblk2p$p
            printf '%s %s %s\n' "$p" "$(cat "$node/start")" "$(cat "$node/size")"
        done
        ;;
    read-p2)
        test "$#" = 3
        ready
        number "$2"; number "$3"
        test "$2" -le 65536 && test "$3" -gt 0 && test "$3" -le 64 &&
            test "$(($2+$3))" -le 65536 || fail 'Invalid read extent'
        test "$(blockdev --getro /dev/mmcblk2p2)" = 1
        dd if=/dev/mmcblk2p2 bs=512 skip="$2" count="$3" status=none
        ;;
    theme)
        test "$#" = 1
        ready
        /bin/sh "$R" probe >/dev/null
        mnt=/run/pb626-net-theme
        mkdir -p "$mnt"
        mount -t ext4 -o ro,noload /dev/mmcblk2p8 "$mnt"
        trap 'status=$?; busybox umount "$mnt" || status=1; exit "$status"' EXIT
        test "$(wc -c <"$mnt/themes/Line.pbt")" = 770198
        cat "$mnt/themes/Line.pbt"
        ;;
    direct)
        shift
        case "$1" in
            write) test "$#" = 8 ;;
            file) test "$#" = 6 ;;
            native-check) test "$#" = 5 ;;
            reset-data|check-data|personalize|bootloader-hash|spl-check) test "$#" = 2 ;;
            *) fail 'Invalid direct operation' ;;
        esac
        cid_check "$2"
        /bin/sh "$D" "$@"
        ;;
    dump-info)
        test "$#" = 2
        case "$2" in emmc) /bin/sh "$R" backup-info;; sd) /bin/sh "$R" sd-info;; *) fail 'Invalid medium';; esac
        ;;
    dump)
        shift
        test "$#" -ge 4
        cid=$1; sectors=$2; op=$3; region=$4
        cid_check "$cid"; number "$sectors"
        case "$region" in
            user|boot0|boot1)
                test "$sectors" = 15269888
                info=$(/bin/sh "$R" probe) ;;
            sd)
                info=$(/bin/sh "$R" sd-info)
                printf '%s\n' "$info" | grep -Fxq "SECTORS=$sectors"
                export PB626_SD_CID="$cid" PB626_SD_SECTORS="$sectors" ;;
            *) fail 'Invalid region' ;;
        esac
        printf '%s\n' "$info" | grep -Fxq "CID=$cid"
        shift 2
        case "$op" in
            backup-read-packed) test "$#" = 3 ;;
            backup-hash|scan|verify) test "$#" = 2 ;;
            write) test "$#" = 6 ;;
            *) fail 'Invalid dump operation' ;;
        esac
        /bin/sh "$R" "$@"
        ;;
    *) fail 'Unknown TCP operation';;
esac
