#!/usr/bin/env bash
# Reuse production Debian userspace, replacing only the kernel and its
# modules in a distinct laboratory rootfs. No device access.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
out=$(realpath -m "${1:?output directory}")
test ! -e "$out"
mkdir "$out"
(cd native-stage && sha256sum -c SHA256SUMS)
(cd deep-resume-lab && sha256sum -c SHA256SUMS)
rev=$(git rev-parse HEAD)
test "$(cat native-stage/BUILD-COMMIT)" = "$rev"
test "$(cat deep-resume-lab/BUILD-COMMIT)" = "$rev"
grep -Fxq 'CONFIG_SUN5I_PM=y' deep-resume-lab/experimental.config
old=$(cat native-stage/KERNELRELEASE)
new=$(cat deep-resume-lab/KERNELRELEASE)
[[ $old =~ ^[a-zA-Z0-9.+_-]+$ && $new =~ ^[a-zA-Z0-9.+_-]+$ && $old != "$new" ]]
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT
mkdir "$work"/{root,modules}
sudo tar --numeric-owner -xzf native-stage/pb626-native-rootfs.tar.gz -C "$work/root"
sudo tar --numeric-owner -xzf deep-resume-lab/kernel-modules.tar.gz -C "$work/modules"
root="$work/root"
test -s "$root/usr/lib/modules/$old/modules.dep"
test -s "$work/modules/lib/modules/$new/modules.dep"
sudo rm -rf "$root/usr/lib/modules/$old"
sudo cp -a "$work/modules/lib/modules/$new" "$root/usr/lib/modules/"
sudo rm -f "$root/usr/lib/modules/$new"/{build,source}
sudo depmod -b "$root" "$new"
test -s "$root/usr/lib/modules/$new/modules.dep"
test ! -e "$root/usr/lib/modules/$old"
module=$(sudo find "$root/usr/lib/modules/$new" -name '*.ko' -print -quit)
test -n "$module"
test "$(modinfo -F vermagic "$module" | cut -d' ' -f1)" = "$new"
grep -Fxq 'MemorySleepMode=s2idle' "$root/etc/systemd/sleep.conf.d/60-pb626.conf"
test ! -e "$root/etc/pb626/suspend-qualified"
bash scripts/build-direct-image.sh "$root" "$out"
cp deep-resume-lab/zImage "$out/pb626-native-zImage"
cp deep-resume-lab/pb626-elan-emmc-native.dtb "$out/"
cp deep-resume-lab/KERNELRELEASE "$out/"
python3 BT0-uncaged/pack-kernel.py "$out/pb626-native-zImage" "$out/pb626-elan-emmc-native.dtb" "$out/raw-linux.img"
(cd "$out" && sha256sum pb626-* KERNELRELEASE raw-linux.img >SHA256SUMS)
