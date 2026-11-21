#!/bin/sh
# Run from the dedicated FEL installer. Only p2 and p8 become writable.
set -eu

fail() { echo "PB626 INSTALL: $*" >&2; exit 1; }
disk=/dev/mmcblk2
sys=/sys/class/block/mmcblk2
boot=${disk}p2
root=${disk}p8
mountpoint=/run/pb626-install
bundle=/opt/pb626-install

[ -f /sys/firmware/devicetree/base/chosen/pb626,emmc-install ] ||
  fail 'Boot elan-emmc-install through FEL first'
[ -r "$sys/device/cid" ] || fail 'MMC2 not found'
cid=$(cat "$sys/device/cid")
[ "$#" -eq 1 ] && [ "$1" = "$cid" ] ||
  fail "This replaces p8. To proceed, run install-pb626-emmc $cid"
[ "$(cat "$sys/device/type")" = MMC ] &&
[ "$(cat "$sys/device/name")" = 8WPD3R ] &&
[ "$(cat "$sys/size")" = 15269888 ] &&
[ "$(cat "$sys/mmcblk2p2/start") $(cat "$sys/mmcblk2p2/size")" = '73728 65536' ] &&
[ "$(cat "$sys/mmcblk2p8/start") $(cat "$sys/mmcblk2p8/size")" = '275456 500736' ] ||
  fail 'Unexpected eMMC layout'
if grep -Eq '^/dev/mmcblk2[^ ]* ' /proc/mounts; then
  fail 'Unmount eMMC before installing'
fi
cd "$bundle"
sha256sum -c SHA256SUMS
mkdir -p "$mountpoint"
cleanup() {
  cd /
  if mountpoint -q "$mountpoint"; then umount "$mountpoint" || return 1; fi
  for dev in "$boot" "$root" "$disk"; do blockdev --setro "$dev" || return 1; done
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mount -t vfat -o ro "$boot" "$mountpoint"
for name in linux normal; do
  config="$mountpoint/linux/$name.ini"
  grep -iqF 'img_name = c:\linux\bImage' "$config.factory" 2>/dev/null ||
    grep -iqF 'img_name = c:\linux\bImage' "$config" ||
    fail "Unexpected factory configuration: $name.ini"
done
test -s "$mountpoint/linux/bImage"
install -m 644 "$mountpoint/default.wbf" /run/pb626-factory.wbf
umount "$mountpoint"

blockdev --setrw "$disk"
blockdev --setrw "$root"
echo 'PB626 INSTALL: writing Alpine to p8'
gzip -dc pb626-emmc-root.ext4.gz > "$root"
sync
mount -t ext4 "$root" "$mountpoint"
test -x "$mountpoint/sbin/pb626-emmc-init"
install -D -m 644 /run/pb626-factory.wbf "$mountpoint/lib/firmware/pb626/default.wbf"
umount "$mountpoint"
blockdev --setro "$root"

blockdev --setrw "$boot"
mount -t vfat "$boot" "$mountpoint"
target="$mountpoint/linux"
echo 'PB626 INSTALL: staging kernel on p2'
cp pb626.bin "$target/pb626.new"
cmp pb626.bin "$target/pb626.new"
mv -f "$target/pb626.new" "$target/pb626.bin"
for name in linux normal; do
  config="$target/$name.ini"
  if [ ! -e "$config.factory" ]; then
    cp "$config" "$config.backup"
    mv "$config.backup" "$config.factory"
  fi
  sed 's/\\bImage/\\pb626.bin/;s/logo_show = 1/logo_show = 0/' "$config.factory" > "$config.new"
  grep -qF 'img_name = c:\linux\pb626.bin' "$config.new"
done
sync
for name in linux normal; do
  mv -f "$target/$name.ini.new" "$target/$name.ini"
done
sync
cleanup
trap - EXIT
echo 'PB626 INSTALL COMPLETE. Reboot without FEL.'
