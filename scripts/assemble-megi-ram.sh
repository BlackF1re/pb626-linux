#!/usr/bin/env bash
# Join independently built kernel, DTBs, and Alpine ARMv7 root.
# FEL artifacts for RAM boot and explicit eMMC installation.
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
test -s kernel-stage/pb626-elan-display.dtb
test -s pb626-epd
gzip -t alpine-base/alpine-rootfs.tar.gz
gzip -t kernel-stage/kernel-modules.tar.gz

sudo tar --numeric-owner -xzf alpine-base/alpine-rootfs.tar.gz -C rootfs
sudo tar --numeric-owner -xzf kernel-stage/kernel-modules.tar.gz -C rootfs
kernel_release=$(cat kernel-stage/KERNELRELEASE)
test -d "rootfs/lib/modules/$kernel_release"
sudo depmod -b rootfs "$kernel_release"

# Alpine 3.24 ships Realtek firmware as .zst, but our downstream A13
# kernel does not currently load it. The reader's RTL8188EU (0bda:8179)
# needs the uncompressed firmware BEFORE rtl8xxxu probes during /init.
firmware=rootfs/lib/firmware/rtlwifi/rtl8188eufw.bin
if [ -s "$firmware.zst" ]; then
  sudo zstd -d -f -q "$firmware.zst" -o "$firmware"
fi
test -s "$firmware"
echo "RTL8188EU uncompressed firmware staged: $(stat -c '%s' "$firmware") bytes"

sudo install -d rootfs/sbin rootfs/usr/sbin rootfs/etc
sudo install -m 755 boot/pb626-init-megi rootfs/sbin/pb626-init
sudo install -m 755 scripts/inspect-live.sh rootfs/usr/sbin/inspect-pb626
sudo install -m 755 scripts/pb626-network.sh rootfs/usr/sbin/pb626-network
sudo install -m 755 pb626-epd rootfs/usr/bin/pb626-epd
printf 'pb626-external-alpine-v1\n' | sudo tee rootfs/etc/pb626-image-id > /dev/null

sudo cp -a rootfs/. initramfs/
sudo install -d initramfs/usr/sbin initramfs/newroot initramfs/sys/kernel/config
sudo install -m 755 boot/init-megi initramfs/init
sudo install -m 755 scripts/inspect-live.sh initramfs/usr/sbin/inspect-pb626
sudo install -m 755 scripts/probe-device.sh initramfs/usr/sbin/probe-pb626
sudo install -m 755 scripts/pb626-network.sh initramfs/usr/sbin/pb626-network
# Explicitly user-authorized public, disposable test-AP credentials (NOT personal).
sudo install -d -m 700 initramfs/etc/pb626
sudo install -m 600 board/megi/wifi-test.conf initramfs/etc/pb626/wpa_supplicant.conf
test -e initramfs/dev/null || sudo mknod -m 666 initramfs/dev/null c 1 3

(cd initramfs && sudo find . -print0 | sudo cpio --null -o --format=newc --quiet) \
  | gzip -9 > dist/pb626-megi-initramfs.cpio.gz

cp kernel-stage/pb626-megi-zImage dist/
cp kernel-stage/pb626-megi.config dist/
cp kernel-stage/KERNELRELEASE kernel-stage/KERNEL-SOURCE.txt dist/
cp kernel-stage/pb626-*.dtb dist/

cp dist/pb626-elan-emmc-install.dtb pb626-emmc-native.dtb
fdtput -d pb626-emmc-native.dtb /chosen pb626,emmc-backup
fdtput -t x pb626-emmc-native.dtb /chosen pb626,emmc-root
fdtput -t s pb626-emmc-native.dtb /chosen bootargs \
  'console=ttyS0,115200 root=/dev/mmcblk2p8 rootwait rootfstype=ext4 rw init=/sbin/pb626-emmc-init'
arm-linux-gnueabihf-as boot/pb626-factory-entry.S -o pb626-emmc-entry.o
arm-linux-gnueabihf-ld -Ttext=0x40008000 -e _start pb626-emmc-entry.o -o pb626-emmc-entry.elf
arm-linux-gnueabihf-objcopy -O binary -j .text pb626-emmc-entry.elf pb626.bin
test "$(stat -c '%s' pb626.bin)" -lt $((0x800000))

sudo install -m 755 boot/init-megi rootfs/sbin/pb626-emmc-init
printf 'pb626-emmc-alpine-v1\n' | sudo tee rootfs/etc/pb626-image-id >/dev/null
truncate -s $((500736 * 512)) pb626-emmc-root.ext4
sudo mkfs.ext4 -q -F -L PB626_ROOT -d rootfs pb626-emmc-root.ext4
gzip -1 pb626-emmc-root.ext4
sudo rm rootfs/sbin/pb626-emmc-init
printf 'pb626-external-alpine-v1\n' | sudo tee rootfs/etc/pb626-image-id >/dev/null
sudo install -D -m 755 scripts/install-pb626-emmc.sh initramfs/usr/sbin/install-pb626-emmc
sudo install -d initramfs/opt/pb626-install
sudo install -m 644 pb626.bin pb626-emmc-root.ext4.gz initramfs/opt/pb626-install/
sha256sum pb626.bin pb626-emmc-root.ext4.gz | sudo tee initramfs/opt/pb626-install/SHA256SUMS >/dev/null
(cd initramfs && sudo find . -print0 | sudo cpio --null -o --format=newc --quiet) \
  | gzip -1 > dist/pb626-emmc-installer.cpio.gz

initrd_start=$((0x45000000))
for dtb in dist/pb626-*.dtb; do
  initrd=dist/pb626-megi-initramfs.cpio.gz
  if [[ ${dtb##*/} == pb626-elan-emmc-install.dtb ]]; then
    initrd=dist/pb626-emmc-installer.cpio.gz
  fi
  initrd_end=$((initrd_start + $(stat -c '%s' "$initrd")))
  test "$initrd_end" -lt $((0x50000000))
  fdtput -t x "$dtb" /chosen linux,initrd-start "$(printf '%x' "$initrd_start")"
  fdtput -t x "$dtb" /chosen linux,initrd-end "$(printf '%x' "$initrd_end")"
  test "$(fdtget -t x "$dtb" /chosen linux,initrd-start)" = "$(printf '%x' "$initrd_start")"
  test "$(fdtget -t x "$dtb" /chosen linux,initrd-end)" = "$(printf '%x' "$initrd_end")"
  if [[ ${dtb##*/} == pb626-elan-emmc-backup.dtb || ${dtb##*/} == pb626-elan-emmc-install.dtb ]]; then
    test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = okay
    test "$(fdtget -t s "$dtb" /soc/mmc@1c0f000 status)" = disabled
    fdtget "$dtb" /chosen pb626,emmc-backup >/dev/null
  else
    test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = disabled
  fi
  test "$(fdtget -t x "$dtb" /backlight default-brightness-level)" = 0
done

sudo tar --numeric-owner -C rootfs -czf dist/pb626-megi-rootfs.tar.gz .
cp kernel-stage/kernel-modules.tar.gz dist/pb626-megi-modules.tar.gz
sudo chown -R "$USER:$USER" dist
gzip -t dist/pb626-megi-initramfs.cpio.gz
gzip -cd dist/pb626-megi-initramfs.cpio.gz | cpio -t > dist/INITRAMFS-CONTENTS.txt 2>/dev/null
(grep -Fxq 'init' dist/INITRAMFS-CONTENTS.txt || grep -Fxq './init' dist/INITRAMFS-CONTENTS.txt)
grep -F '/rtl8188eufw.bin' dist/INITRAMFS-CONTENTS.txt >/dev/null
(grep -Fxq 'etc/pb626/wpa_supplicant.conf' dist/INITRAMFS-CONTENTS.txt || \
 grep -Fxq './etc/pb626/wpa_supplicant.conf' dist/INITRAMFS-CONTENTS.txt)
grep -F '/sun5i-eink.ko' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F '/pb626-epd' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F '/rtl8xxxu.ko' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F '/aireplay-ng' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F '/hcxdumptool' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F 'lib/modules/' dist/INITRAMFS-CONTENTS.txt >/dev/null
rm dist/INITRAMFS-CONTENTS.txt

(cd dist && sha256sum pb626-megi-zImage *.dtb *.gz *.config > SHA256SUMS)
cat > dist/README.txt <<'NOTE'
EXPERIMENTAL ALPINE FOR POCKETBOOK 626 PLUS.
Megi mainline Linux 7.2 (2026-09-03), commit facc87117511221bb61410e3f92ad8579697f736.
2026 sun4i timer fixes already upstream.
The first FEL Linux boot blinked LED but did not enumerate 0525:a4a7.
This image has new UDC LED codes and an attempted frontlight-off fix.
DTB variants: four standard, plus elan-lightoff, elan-usbtest and elan-display.
elan-lightoff: disable backlight/PWM and hog PB4 LOW, KEEP factory PG1
VBUS detect. Test this variant FIRST and verify that frontlight goes off.
elan-usbtest: same PB4-off configuration, plus experimental PG1 fallback.
Use it ONLY AFTER the elan-lightoff test is safe and without other changes.
elan-display: ELAN / ED060XD4 with PWM backlight, USB ACM and both MMC hosts off.
elan-emmc-backup: dedicated USB backup from RAM with read-only eMMC and SD off.
elan-emmc-install: FEL installer, writes eMMC only after install-pb626-emmc CID.
Never use these experimental DTBs on a reader with unverified GPIO pinout.
Optional removable rootfs needs explicit pb626.root=sd and is read-only.
SPL/ARM entry are external lab dependencies and remain unreviewed.
NOTE
test -s dist/pb626-megi-zImage
test -s dist/pb626-megi-initramfs.cpio.gz
test -s dist/pb626-megi-rootfs.tar.gz
test -s dist/KERNEL-SOURCE.txt
echo 'FULL RAM BUNDLE VERIFIED'
