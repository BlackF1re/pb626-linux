#!/usr/bin/env bash
# All paths are private local files. No physical disk is opened here.
set -Eeuo pipefail
[[ $# = 4 ]] || { echo 'Usage: prepare-install.sh STOCK SYSTEM FEL_INPUTS OUTPUT' >&2; exit 2; }
repo=$(cd "$(dirname "$0")/.." && pwd)
stock=$(realpath "$1"); system=$(realpath "$2"); lab=$(realpath "$3"); output=$(realpath -m "$4")
test "$(id -u)" = 0
test ! -e "$output"
for tool in python3 mcopy mtype clang ld.lld llvm-objcopy debugfs mke2fs e2fsck fdtget openssl; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
# Existing builder independently checks the full backup, identity, original
# partition geometry, immutable regions, waveform, and SPL fingerprints.
test -f "$stock/SHA256SUMS"
mcopy -i "$stock/pb626-emmc-user.img@@37748736" ::/default.wbf "$work/default.wbf"
vcom=$(mtype -i "$stock/pb626-emmc-user.img@@37748736" ::/vcom | tr -d '\r\n')
[[ "$vcom" = -2440 ]] || { echo 'Wrong factory VCOM: stop' >&2; exit 1; }
printf '%s  %s\n' bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f "$work/default.wbf" | sha256sum -c -
python3 "$repo/BT0-uncaged/build.py" "$lab/pb626-spl.bin" "$work/BT0-uncaged.bin"
python3 "$repo/BT0-uncaged/test_hook.py" "$work/BT0-uncaged.bin"
python3 "$repo/scripts/build-native-image.py" --backup "$stock" --system "$system" \
    --spl "$work/BT0-uncaged.bin" --waveform "$work/default.wbf" --output "$output" --accept-replace-p1
