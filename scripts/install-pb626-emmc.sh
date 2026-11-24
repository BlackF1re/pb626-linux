#!/bin/sh
# Only the dedicated FEL installer may run this. p1 is intentionally erased.
# Keep factory BT0/BT1, partition geometry, p2 boot files and p5-p10.
set -eu
set -o pipefail
fail() { echo "PB626 INSTALL FAILED: $*" >&2; exit 1; }
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
disk=/dev/mmcblk2
sys=/sys/class/block/mmcblk2
root=${disk}p1
boot=${disk}p2
mnt=/run/pb626-install
kit=/opt/pb626-install
chosen=/sys/firmware/devicetree/base/chosen
stock_ini=e625a04b8c6c2057f8a94ae3cff3fbd927896353cc4b3c5dd4e41a5a45d48443
[ "$#" = 2 ] && [ "$1" = --erase-p1 ] || fail 'usage: install-pb626-emmc --erase-p1 EXPECTED_CID'
[ -f "$chosen/pb626,emmc-install" ] && [ -f "$chosen/pb626,emmc-backup" ] || fail 'Not the dedicated FEL installer'
[ -r "$sys/device/cid" ] && [ "$(cat "$sys/device/cid")" = "$2" ] || fail 'CID mismatch'
[ "$(cat "$sys/device/type")" = MMC ] && [ "$(cat "$sys/device/name")" = 8WPD3R ] &&
[ "$(cat "$sys/size")" = 15269888 ] &&
[ "$(cat "$sys/mmcblk2p1/start") $(cat "$sys/mmcblk2p1/size")" = '1009664 14260224' ] &&
[ "$(cat "$sys/mmcblk2p2/start") $(cat "$sys/mmcblk2p2/size")" = '73728 65536' ] ||
    fail 'Unexpected internal storage geometry'
! grep -Eq '^/dev/mmcblk2[^ ]* ' /proc/mounts || fail 'eMMC already mounted'
cd "$kit"
sha256sum -c SHA256SUMS
[ "$(cat KERNELRELEASE)" = "$(uname -r)" ] || fail 'Installer kernel does not match root modules'
[ "$(stat -c %s pb626.bin)" -le 8388608 ] || fail 'Payload exceeds 8 MiB'
# Exact factory loader identities from the verified original dump. No writes
# to these ranges. This rejects other board revisions and damaged backups.
check_range() {
    got=$(dd if="$disk" bs=512 skip="$1" count="$2" 2>/dev/null | sha256sum)
    [ "${got%% *}" = "$3" ] || fail "Unexpected stock loader at LBA $1"
}
check_range 16 42 245b81edb1f1ffa51738f33548f793500f2fab9b00c150df9f1ee78b81667824
check_range 38192 448 3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227
check_range 38704 448 3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227
mkdir -p "$mnt"
cleanup() {
    cd /
    if mountpoint -q "$mnt"; then umount "$mnt" || true; fi
    blockdev --setro "$root" || true
    blockdev --setro "$boot" || true
    blockdev --setro "$disk" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mount -t vfat -o ro "$boot" "$mnt"
printf '%s  %s\n' \
    e69ffc56fff409611a86687a85fdb6fb2ecc60fe88d843fa40c08f351f614c08 "$mnt/boot.axf" \
    18384f34e5b9305c2109998d9c0c3a65042fb1edc058a5c109918169a8e429fe "$mnt/linux/bImage" \
    6133d6d7d3042d88d0b23b65490cc6a9f134002e0b0176e0dea51e51bdc09bc2 "$mnt/script.bin" |
    sha256sum -c -
factory="$mnt/linux/linux.ini"
if [ -f "$mnt/linux/linux.ini.factory" ]; then factory="$mnt/linux/linux.ini.factory"; fi
printf '%s  %s\n' "$stock_ini" "$factory" | sha256sum -c -
# Require an authentic factory calibration and waveform, never ship a WBF.
[ "$(stat -c %s "$mnt/default.wbf")" = 103662 ] || fail 'Unexpected waveform'
[ "$(cat "$mnt/vcom")" = -2440 ] || fail 'Unexpected panel VCOM; do not use this ELAN image'
cp "$mnt/default.wbf" /run/pb626-factory.wbf
# Ensure enough FAT space BEFORE destroying p1. Need room for a staged image.
available=$(df -k "$mnt" | awk 'NR==2 {print $4}')
needed=$(( ($(stat -c %s pb626.bin) + 1023) / 1024 + 64 ))
[ "$available" -ge "$needed" ] || fail 'Insufficient free space on p2'
umount "$mnt"
echo 'PB626 INSTALL: formatting user p1 (all former user files are erased)'
blockdev --setrw "$disk"
blockdev --setrw "$root"
mke2fs -t ext4 -F -m 0 -L PB626_ROOT -E nodiscard "$root"
mount -t ext4 "$root" "$mnt"
echo 'PB626 INSTALL: extracting complete Alpine Desktop'
tar -xzpf "$kit/rootfs.tar.gz" -C "$mnt"
# Independently check every regular file against the host manifest.
if ! (cd "$mnt" && sha256sum -c "$kit/ROOT-SHA256SUMS") >/run/pb626-root-verify.log 2>&1; then
    tail -n 30 /run/pb626-root-verify.log >&2
    fail 'Root filesystem read-back mismatch'
fi
[ -x "$mnt/bin/busybox" ] && [ -L "$mnt/sbin/init" ] &&
[ -x "$mnt/sbin/pb626-native-setup" ] &&
[ -x "$mnt/usr/bin/Xorg" ] && [ -x "$mnt/usr/bin/pb626-epd" ] &&
[ -x "$mnt/usr/bin/pb626-x11-epd" ] &&
[ -d "$mnt/lib/modules/$(uname -r)" ] || fail 'Incomplete native root'
mkdir -p "$mnt/lib/firmware/pb626"
cp /run/pb626-factory.wbf "$mnt/lib/firmware/pb626/default.wbf"
cmp /run/pb626-factory.wbf "$mnt/lib/firmware/pb626/default.wbf"
sync
umount "$mnt"
e2fsck -fn "$root"
blockdev --setro "$root"
echo 'PB626 INSTALL: staging verified payload on p2'
blockdev --setrw "$boot"
mount -t vfat "$boot" "$mnt"
target="$mnt/linux"
if [ ! -e "$target/linux.ini.factory" ]; then
    cp "$target/linux.ini" "$target/linux.ini.factory"
fi
printf '%s  %s\n' "$stock_ini" "$target/linux.ini.factory" | sha256sum -c -
# Preserve CRLF and all other factory settings; replace only the filename
# and disable the old logo. The explicit DTB supplies the Linux bootargs.
sed 's|c:\\linux\\bImage|c:\\linux\\pb626.bin|;s/^logo_show = 1/logo_show = 0/' \
    "$target/linux.ini.factory" >"$target/linux.new"
grep -qiF 'img_name = c:\linux\pb626.bin' "$target/linux.new"
grep -qiF 'img_base = 0x40008000' "$target/linux.new"
grep -qiF 'img_size = 0x800000' "$target/linux.new"
cp "$kit/pb626.bin" "$target/pb626.new"
cmp "$kit/pb626.bin" "$target/pb626.new"
sync
mv -f "$target/pb626.new" "$target/pb626.bin"
sync
# Activate ONLY after root, filesystem check and boot payload verified.
mv -f "$target/linux.new" "$target/linux.ini"
sync
umount "$mnt"
mount -t vfat -o ro "$boot" "$mnt"
cmp "$kit/pb626.bin" "$mnt/linux/pb626.bin"
grep -qiF 'img_name = c:\linux\pb626.bin' "$mnt/linux/linux.ini"
printf '%s  %s\n' "$stock_ini" "$mnt/linux/linux.ini.factory" | sha256sum -c -
umount "$mnt"
blockdev --setro "$root"
blockdev --setro "$boot"
blockdev --setro "$disk"
for node in "$root" "$boot" "$disk"; do
    [ "$(blockdev --getro "$node")" = 1 ] || fail 'Could not restore read-only protection'
done
trap - EXIT
echo 'PB626 INSTALL COMPLETE'
