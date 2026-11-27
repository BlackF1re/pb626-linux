#!/usr/bin/env bash
# The RAM image consists of Debian 13's signed armhf busybox-static,
# the project recovery helper and the paired kernel/DTB. No desktop,
# systemd, APT database, kernel modules, Wi-Fi firmware or eMMC mounts.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
kernel=$(realpath "${1:?kernel stage}")
out=$(realpath -m "${2:?output directory}")
test ! -e "$out"
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT
cd "$repo"
# Cache the signed ARM BusyBox and scanner independently of kernel and
# installer packaging. The workflow keys this by toolchain/inputs/epoch.
payload=${3:-"$work/recovery-payload"}
if [ ! -f "$payload/SHA256SUMS" ]; then
sudo mmdebstrap --mode=root --variant=extract --architectures=amd64 \
    --include=debian-archive-keyring --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    bookworm "$work/keys" 'deb http://deb.debian.org/debian bookworm main'
keyring="$work/keys/usr/share/keyrings/debian-archive-keyring.gpg"
test -s "$keyring"
sudo mmdebstrap --mode=root --variant=extract --architectures=armhf \
    --include=busybox-static --keyring="$keyring" \
    trixie "$work/debian" 'deb http://deb.debian.org/debian trixie main'
busybox="$work/debian/usr/bin/busybox"
test -f "$busybox" && test -x "$busybox"

    mkdir -p "$payload"
    sudo install -m 755 "$busybox" "$payload/busybox"
    sudo install -m 644 "$work/debian/usr/share/doc/busybox-static/copyright" "$payload/DEBIAN-BUSYBOX-COPYRIGHT"
    arm-linux-gnueabihf-gcc -O2 -Wall -Wextra -Werror -static -s scripts/restore/pb626-restore-scan.c -o "$payload/scanner"
    sudo chown "$(id -u):$(id -g)" "$payload"/{busybox,DEBIAN-BUSYBOX-COPYRIGHT}
    (cd "$payload" && sha256sum busybox scanner DEBIAN-BUSYBOX-COPYRIGHT >SHA256SUMS)
fi
(cd "$payload" && sha256sum -c SHA256SUMS)
busybox="$payload/busybox"
root="$work/root"
sudo install -d "$root"/{bin,sbin,usr/bin,usr/sbin,usr/libexec,dev,proc,sys,run,root,tmp,etc,sys/kernel/config}
sudo install -m 755 "$busybox" "$root/bin/busybox"
applets=$(sudo qemu-arm "$root/bin/busybox" --list)
for applet in sh ash awk base64 basename blockdev cat chmod cp dd grep gzip head ln mkdir mktemp mount mv readlink rm seq setsid sha256sum sleep stty sync timeout touch tr wc; do
    grep -Fxq "$applet" <<<"$applets"
    sudo ln -s busybox "$root/bin/$applet"
done
sudo ln -s ../bin/busybox "$root/sbin/poweroff"
sudo ln -s ../bin/busybox "$root/sbin/reboot"
sudo install -m 755 boot/recovery/init "$root/init"
sudo install -m 755 scripts/restore/{pb626-restore-fast.sh,pb626-install-direct.sh} "$root/usr/libexec/"
sudo install -m 755 "$payload/scanner" "$root/usr/libexec/pb626-restore-scan"
printf 'pb626-debian13-recovery-v1\n' | sudo tee "$root/etc/pb626-image-id" >/dev/null
sudo mknod -m 600 "$root/dev/console" c 5 1
sudo mknod -m 666 "$root/dev/null" c 1 3
sudo chmod 1777 "$root/tmp"
# Verify actual target executable and options used by the protocol.
sudo qemu-arm "$root/bin/busybox" sh -n "$root/init"
sudo qemu-arm "$root/bin/busybox" sh -n "$root/usr/libexec/pb626-restore-fast.sh"
(sudo qemu-arm "$root/bin/busybox" blockdev --help 2>&1 || :) | grep -- --getsz >/dev/null
(sudo qemu-arm "$root/bin/busybox" setsid --help 2>&1 || :) | grep -- '-c' >/dev/null
mkdir -p "$out"/{recovery,tools,source}
cp "$kernel/pb626-megi-zImage" "$out/recovery/"
printf '\0\0\0\0' >> "$out/recovery/pb626-megi-zImage"
cp "$kernel/pb626-elan-emmc-backup.dtb" "$out/recovery/"
dtb="$out/recovery/pb626-elan-emmc-backup.dtb"
fdtget "$dtb" /chosen pb626,emmc-backup >/dev/null
test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = okay
test "$(fdtget -t s "$dtb" /soc/mmc@1c0f000 status)" = disabled
# Keep the validated eMMC-only DTB untouched. The separate opt-in SD
# profile uses the same conservative parameters as native SD experiments.
sd_dtb="$out/recovery/pb626-elan-emmc-sd-backup.dtb"
cp "$dtb" "$sd_dtb"
sd_node=/soc/mmc@1c0f000
fdtput -t s "$sd_dtb" "$sd_node" status okay
fdtput -t u "$sd_dtb" "$sd_node" max-frequency 12500000
fdtput -t u "$sd_dtb" /regulator-mmc0 startup-delay-us 20000
for prop in no-1-8-v disable-wp no-mmc no-sdio; do
    fdtput "$sd_dtb" "$sd_node" "$prop"
done
fdtput "$sd_dtb" /chosen pb626,sd-backup
test "$(fdtget -t s "$sd_dtb" /soc/mmc@1c11000 status)" = okay
test "$(fdtget -t u "$sd_dtb" "$sd_node" bus-width)" = 4
fdtget "$sd_dtb" "$sd_node" cd-gpios >/dev/null
fdtget "$sd_dtb" "$sd_node" vmmc-supply >/dev/null
ram="$out/recovery/pb626-megi-initramfs.cpio.gz"
(cd "$root" && sudo find . -print0 | sudo cpio --null -o --format=newc --quiet) | gzip -n -9 >"$ram"
# Keep this deliberately small; FEL transfers every byte with readback.
test "$(stat -c '%s' "$ram")" -lt 4194304
end=$((0x45000000 + $(stat -c '%s' "$ram")))
for dtb in "$out/recovery/"*.dtb; do
    fdtput -t x "$dtb" /chosen linux,initrd-start 45000000
    fdtput -t x "$dtb" /chosen linux,initrd-end "$(printf '%x' "$end")"
done
cp scripts/{fel-boot.sh,Start-PB626.ps1} "$out/recovery/"
git rev-parse HEAD >"$out/recovery/BUILD-COMMIT"
(cd "$out/recovery" && sha256sum pb626-megi-zImage *.dtb *.gz BUILD-COMMIT fel-boot.sh Start-PB626.ps1 > SHA256SUMS)
cp scripts/restore/{Backup-PB626Fast.ps1,Restore-PB626Fast.ps1,pb626-restore-fast.sh,README.md} "$out/tools/"
gzip -n -9 -c "$payload/scanner" >"$out/tools/pb626-restore-scan.gz"
(cd "$out/tools" && sha256sum pb626-restore-scan.gz > SHA256SUMS.fast && sha256sum *.ps1 *.sh *.gz README.md SHA256SUMS.fast > SHA256SUMS)
cp -a BT0-uncaged "$out/source/"
mkdir -p "$out/source/scripts"
cp scripts/{build-native-image.py,pb626_sleep_theme.py,prepare-install.sh} "$out/source/scripts/"
cp scripts/installer/{PB626.ps1,PB626.cmd,pb626.sh,install-direct.py} "$out/"
cp LICENSE "$out/"
cp "$payload/DEBIAN-BUSYBOX-COPYRIGHT" "$out/recovery/DEBIAN-BUSYBOX-COPYRIGHT"
echo "Debian recovery initramfs: $(stat -c '%s' "$ram") bytes"
