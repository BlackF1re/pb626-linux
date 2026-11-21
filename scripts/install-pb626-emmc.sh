#!/bin/sh
# Run from the FEL installer, or update the boot files alone from FEL backup.
set -eu

fail() { echo "PB626 INSTALL: $*" >&2; exit 1; }
disk=/dev/mmcblk2
sys=/sys/class/block/mmcblk2
boot=${disk}p2
root=${disk}p8
mountpoint=/run/pb626-install
bundle=/opt/pb626-install

chosen=/sys/firmware/devicetree/base/chosen
boot_only=0
if [ "${1:-}" = --boot-only ]; then
  boot_only=1
  shift
fi
if [ ! -f "$chosen/pb626,emmc-install" ]; then
  [ "$boot_only" = 1 ] && [ -f "$chosen/pb626,emmc-backup" ] ||
    fail 'Boot elan-emmc-install through FEL first'
fi
[ -r "$sys/device/cid" ] || fail 'MMC2 not found'
cid=$(cat "$sys/device/cid")
[ "$#" -eq 1 ] && [ "$1" = "$cid" ] ||
  fail "Pass the target eMMC CID to proceed: $cid"
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
sha256sum -c BOOT-SHA256SUMS
[ "$boot_only" = 1 ] || sha256sum -c SHA256SUMS
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
if [ -e "$mountpoint/linux/bImage.pb" ]; then
  test -s "$mountpoint/linux/bImage.pb"
else
  test -s "$mountpoint/linux/bImage"
fi
[ "$boot_only" = 1 ] || install -m 644 "$mountpoint/default.wbf" /run/pb626-factory.wbf
umount "$mountpoint"

if [ "$boot_only" = 1 ]; then
  mount -t ext4 -o ro,noload "$root" "$mountpoint"
  [ "$(cat "$mountpoint/etc/pb626-image-id")" = pb626-emmc-alpine-v1 ] ||
    fail 'Installed Alpine filesystem not found'
  test -x "$mountpoint/sbin/pb626-emmc-init"
  umount "$mountpoint"
else
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
fi

blockdev --setrw "$disk"
blockdev --setrw "$boot"
mount -t vfat "$boot" "$mountpoint"
target="$mountpoint/linux"
echo 'PB626 INSTALL: staging Linux boot files on p2'
# Retire unused payloads from installs that used separate boot segments.
legacy_configs=$(grep -ilE 'pbkern\.bin|pbdt\.bin|pb626rd\.gz' "$target"/*.ini || [ "$?" -eq 1 ])
if [ -z "$legacy_configs" ]; then
  rm -f "$target/pbkern.bin" "$target/pbdt.bin" "$target/pb626rd.gz"
fi
rm -f "$target/bImage.new"
if ! cp bImage "$target/bImage.new"; then
  rm -f "$target/bImage.new"
  fail 'Cannot stage bImage on the boot partition'
fi
cmp bImage "$target/bImage.new"
for name in recovery calibrate; do
  config="$target/$name.ini"
  if [ ! -e "$config.factory" ]; then
    cp "$config" "$config.backup"
    mv "$config.backup" "$config.factory"
  fi
  sed 's/\\bImage/\\bImage.pb/' "$config.factory" > "$config.new"
  grep -qiF 'img_name = c:\linux\bImage.pb' "$config.new"
done
for name in linux normal; do
  config="$target/$name.ini"
  if [ ! -e "$config.factory" ]; then
    cp "$config" "$config.backup"
    mv "$config.backup" "$config.factory"
  fi
  awk '
    BEGIN { ORS = "\r\n" }
    { sub(/\r$/, "") }
    /^logo_show / { $0 = "logo_show = 0" }
    { print }
  ' "$config.factory" > "$config.new"
  grep -qiF 'img_name = c:\linux\bImage' "$config.new"
  grep -qF 'img_size = 0x800000' "$config.new"
done
sync
if [ ! -e "$target/bImage.pb" ]; then
  mv "$target/bImage" "$target/bImage.pb"
fi
mv -f "$target/bImage.new" "$target/bImage"
for name in linux normal recovery calibrate; do
  mv -f "$target/$name.ini.new" "$target/$name.ini"
done
sync
umount "$mountpoint"
mount -t vfat -o ro "$boot" "$mountpoint"
cmp bImage "$target/bImage"
grep -qF 'img_size = 0x800000' "$target/linux.ini"
cleanup
trap - EXIT
echo 'PB626 INSTALL COMPLETE. Reboot without FEL.'
