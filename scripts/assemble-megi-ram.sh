#!/usr/bin/env bash
# Join independently built kernel, DTBs, and Alpine ARMv7 root.
# RAM-only FEL artifact; no commands that write to eMMC.
set -Eeuo pipefail
trap 'echo "RAM BUNDLE ASSEMBLY ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
echo '=== kernel-stage ==='
find kernel-stage -maxdepth 2 -type f -printf '%p %s bytes\n' | sort
echo '=== alpine-base ==='
find alpine-base -maxdepth 2 -type f -printf '%p %s bytes\n' | sort
mkdir -p dist rootfs initramfs
test -s kernel-stage/pb626-megi-zImage
test -s kernel-stage/kernel-modules.tar.gz
test -s kernel-stage/KERNELRELEASE
test -s alpine-base/alpine-rootfs.tar.gz
test "$(find kernel-stage -maxdepth 1 -name 'pb626-*.dtb' | wc -l)" -eq 6
gzip -t alpine-base/alpine-rootfs.tar.gz
gzip -t kernel-stage/kernel-modules.tar.gz

sudo tar --numeric-owner -xzf alpine-base/alpine-rootfs.tar.gz -C rootfs
sudo tar --numeric-owner -xzf kernel-stage/kernel-modules.tar.gz -C rootfs
kernel_release=$(cat kernel-stage/KERNELRELEASE)
test -d "rootfs/lib/modules/$kernel_release"
sudo depmod -b rootfs "$kernel_release"

sudo install -d rootfs/sbin rootfs/usr/sbin rootfs/etc
sudo install -m 755 boot/pb626-init-megi rootfs/sbin/pb626-init
sudo install -m 755 scripts/inspect-live.sh rootfs/usr/sbin/inspect-pb626
sudo install -m 755 scripts/pb626-network.sh rootfs/usr/sbin/pb626-network
printf 'pb626-external-alpine-v1\n' | sudo tee rootfs/etc/pb626-image-id > /dev/null

sudo cp -a rootfs/. initramfs/
sudo install -d initramfs/usr/sbin initramfs/newroot initramfs/sys/kernel/config
sudo install -m 755 boot/init-megi initramfs/init
sudo install -m 755 scripts/inspect-live.sh initramfs/usr/sbin/inspect-pb626
sudo install -m 755 scripts/probe-device.sh initramfs/usr/sbin/probe-pb626
sudo install -m 755 scripts/pb626-network.sh initramfs/usr/sbin/pb626-network
test -e initramfs/dev/null || sudo mknod -m 666 initramfs/dev/null c 1 3

(cd initramfs && sudo find . -print0 | sudo cpio --null -o --format=newc --quiet) \
  | gzip -9 > dist/pb626-megi-initramfs.cpio.gz

cp kernel-stage/pb626-megi-zImage dist/
cp kernel-stage/pb626-megi.config dist/
cp kernel-stage/KERNELRELEASE kernel-stage/KERNEL-SOURCE.txt dist/
cp kernel-stage/pb626-*.dtb dist/

initrd_start=$((0x45000000))
initrd_size=$(stat -c '%s' dist/pb626-megi-initramfs.cpio.gz)
initrd_end=$((initrd_start + initrd_size))
test "$initrd_end" -lt $((0x50000000))
for dtb in dist/pb626-*.dtb; do
  fdtput -t x "$dtb" /chosen linux,initrd-start "$(printf '%x' "$initrd_start")"
  fdtput -t x "$dtb" /chosen linux,initrd-end "$(printf '%x' "$initrd_end")"
  test "$(fdtget -t x "$dtb" /chosen linux,initrd-start)" = "$(printf '%x' "$initrd_start")"
  test "$(fdtget -t x "$dtb" /chosen linux,initrd-end)" = "$(printf '%x' "$initrd_end")"
  test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = disabled
  test "$(fdtget -t x "$dtb" /backlight default-brightness-level)" = 0
done

sudo tar --numeric-owner -C rootfs -czf dist/pb626-megi-rootfs.tar.gz .
cp kernel-stage/kernel-modules.tar.gz dist/pb626-megi-modules.tar.gz
sudo chown -R "$USER:$USER" dist
gzip -t dist/pb626-megi-initramfs.cpio.gz
gzip -cd dist/pb626-megi-initramfs.cpio.gz | cpio -t > dist/INITRAMFS-CONTENTS.txt 2>/dev/null
(grep -Fxq 'init' dist/INITRAMFS-CONTENTS.txt || grep -Fxq './init' dist/INITRAMFS-CONTENTS.txt)
grep -F '/sun5i-eink.ko' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F '/rtl8xxxu.ko' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F 'lib/modules/' dist/INITRAMFS-CONTENTS.txt >/dev/null
rm dist/INITRAMFS-CONTENTS.txt

(cd dist && sha256sum pb626-megi-zImage *.dtb *.gz *.config > SHA256SUMS)
cat > dist/README.txt <<'NOTE'
EXPERIMENTAL FULL RAM ALPINE. NEVER FLASH INTERNAL EMMC.
Megi mainline Linux 7.2 (2026-09-03), commit facc87117511221bb61410e3f92ad8579697f736.
2026 sun4i timer fixes already upstream.
The first FEL Linux boot blinked LED but did not enumerate 0525:a4a7.
This image has new UDC LED codes and an attempted frontlight-off fix.
Six DTB variants: four standard, plus elan-lightoff and elan-usbtest.
elan-lightoff: disable backlight/PWM and hog PB4 LOW, KEEP factory PG1
VBUS detect. Test this variant FIRST and verify that frontlight goes off.
elan-usbtest: same PB4-off configuration, plus experimental PG1 fallback.
Use it ONLY AFTER the elan-lightoff test is safe and without other changes.
Never use these experimental DTBs on a reader with unverified GPIO pinout.
Optional removable rootfs needs explicit pb626.root=sd and is read-only.
SPL/ARM entry are external lab dependencies and remain unreviewed.
NOTE
test -s dist/pb626-megi-zImage
test -s dist/pb626-megi-initramfs.cpio.gz
test -s dist/pb626-megi-rootfs.tar.gz
test -s dist/KERNEL-SOURCE.txt
echo 'FULL RAM BUNDLE VERIFIED'
