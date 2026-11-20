#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then echo "usage: make-sd-image.sh ROOTFS OUTPUT.img" >&2; exit 2; fi
rootfs=$1
image=$2
if [[ ! -d "$rootfs" || -e "$image" || "$image" != *.img ]]; then
    echo "Expected an existing rootfs directory and a new .img output file" >&2
    exit 2
fi
for cmd in sfdisk mke2fs e2fsck mkfs.vfat mcopy dd truncate; do
    command -v "$cmd" >/dev/null || { echo "Missing tool: $cmd" >&2; exit 1; }
done
mkdir -p "$(dirname "$image")"
part="${image%.img}.ext4.tmp"
cfg="${image%.img}.fat.tmp"
trap 'rm -f "$part" "$cfg"' EXIT

# 1024 MiB disk: 1 MiB MBR gap, 959 MiB Linux root (p1),
# 64 MiB FAT32 host-writable configuration partition (p2).
truncate -s 1024M "$image"
printf 'label: dos\nunit: sectors\n\nstart=2048, size=1964032, type=83\nstart=1966080, size=131072, type=c\n' |
    sfdisk "$image" >/dev/null
truncate -s 959M "$part"
mke2fs -q -F -t ext4 -L PB626_ROOT -O ^64bit,^metadata_csum -d "$rootfs" "$part"
e2fsck -fn "$part" >/dev/null

truncate -s 64M "$cfg"
mkfs.vfat -F 32 -n PB626CFG "$cfg" >/dev/null
printf '%s\n' 'PocketBook FEL test configuration' 'Optional: place wifi.conf here in standard wpa_supplicant format.' 'Never flash the factory eMMC.' > README.TXT
mcopy -i "$cfg" README.TXT ::README.TXT
rm README.TXT
dd if="$part" of="$image" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$cfg" of="$image" bs=1M seek=960 conv=notrunc,sparse status=none
sfdisk -d "$image" | grep -q 'start= *2048, size= *1964032'
sfdisk -d "$image" | grep -q 'start= *1966080, size= *131072'
echo "Prepared removable microSD image: $image (1024 MiB)"
