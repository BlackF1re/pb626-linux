#!/usr/bin/env bash
# Build the generic exact-size ext4 image and public Menu hook in CI.
# No device-specific data or password is included. Never open a block device.
set -Eeuo pipefail
root=$(realpath "$1")
out=$(realpath "$2")
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
test -d "$root"
test "$(sudo cat "$root/etc/pb626-image-id")" = pb626-native-debian13-armhf-v1
sudo awk -F: '$1=="root" && $2 ~ /^[!*]/ {n++} END {exit n!=1}' "$root/etc/shadow"
test ! -e "$root/lib/firmware/pb626/default.wbf"
echo 'Creating exact-size flashable ext4 image (generic, locked root)...'
truncate -s $((14260224*512)) "$work/p1.ext4"
# Explicit 4 KiB block size and initialized metadata, as in the offline builder.
sudo mke2fs -q -F -t ext4 -b 4096 -E lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$work/p1.ext4"
sudo e2fsck -fn "$work/p1.ext4"
test "$(stat -c %s "$work/p1.ext4")" = 7301234688
python3 "$repo/scripts/build-rootfs-bmap.py" "$work/p1.ext4" "$out/pb626-rootfs.bmap.json"
gzip -1 -n -c "$work/p1.ext4" > "$out/pb626-rootfs.ext4.gz.partial"
gzip -t "$out/pb626-rootfs.ext4.gz.partial"
mv "$out/pb626-rootfs.ext4.gz.partial" "$out/pb626-rootfs.ext4.gz"
clang --target=armv7a-none-eabi -c "$repo/BT0-uncaged/early-menu.S" -o "$work/menu.o"
ld.lld --image-base=0x0 -Ttext=0x5000 -e _start "$work/menu.o" -o "$work/menu.elf"
llvm-objcopy -O binary -j .text "$work/menu.elf" "$out/pb626-bt0-menu.raw"
python3 "$repo/BT0-uncaged/test_hook.py" --hook-only "$out/pb626-bt0-menu.raw"
echo 'Ready-to-flash rootfs and exact verified BT0 patch assembled.'
