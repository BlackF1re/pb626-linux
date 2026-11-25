#!/usr/bin/env bash
# Join independently built kernel, DTBs, and Alpine ARMv7 root.
# FEL artifacts for RAM boot and read-only eMMC recovery.
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
sudo install -m 755 scripts/inspect-live.sh rootfs/usr/sbin/inspect-pb626
sudo install -m 755 scripts/pb626-network.sh rootfs/usr/sbin/pb626-network
sudo install -m 755 pb626-epd rootfs/usr/bin/pb626-epd
printf 'pb626-ram-alpine-v1\n' | sudo tee rootfs/etc/pb626-image-id > /dev/null

sudo cp -a rootfs/. initramfs/
sudo install -d initramfs/usr/sbin initramfs/sys/kernel/config
sudo install -m 755 boot/init-megi initramfs/init
sudo install -m 755 scripts/inspect-live.sh initramfs/usr/sbin/inspect-pb626
sudo install -m 755 scripts/probe-device.sh initramfs/usr/sbin/probe-pb626
sudo install -m 755 scripts/pb626-network.sh initramfs/usr/sbin/pb626-network
sudo install -d -m 700 initramfs/etc/pb626
test -e initramfs/dev/null || sudo mknod -m 666 initramfs/dev/null c 1 3

(cd initramfs && sudo find . -print0 | sudo cpio --null -o --format=newc --quiet) \
  | gzip -9 > dist/pb626-megi-initramfs.cpio.gz

cp kernel-stage/pb626-megi-zImage dist/
cp kernel-stage/pb626-megi.config dist/
cp kernel-stage/KERNELRELEASE kernel-stage/KERNEL-SOURCE.txt dist/
cp kernel-stage/pb626-*.dtb dist/
cp kernel-stage/pb626-megi-zImage dist/pb626-native-zImage
cp -r kernel-stage/uapi dist/

# Reserve a zero word at the appended-DTB probe address in FEL images.
printf '\0\0\0\0' >> dist/pb626-megi-zImage
initrd_start=$((0x45000000))

for dtb in dist/pb626-*.dtb; do
  if [[ ${dtb##*/} == pb626-elan-emmc-native.dtb ]]; then
    fdtget "$dtb" /chosen pb626,emmc-root >/dev/null
    test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = okay
    ! fdtget "$dtb" /chosen linux,initrd-start >/dev/null 2>&1
    continue
  fi
  initrd=dist/pb626-megi-initramfs.cpio.gz
  initrd_end=$((initrd_start + $(stat -c '%s' "$initrd")))
  test "$initrd_end" -lt $((0x50000000))
  fdtput -t x "$dtb" /chosen linux,initrd-start "$(printf '%x' "$initrd_start")"
  fdtput -t x "$dtb" /chosen linux,initrd-end "$(printf '%x' "$initrd_end")"
  test "$(fdtget -t x "$dtb" /chosen linux,initrd-start)" = "$(printf '%x' "$initrd_start")"
  test "$(fdtget -t x "$dtb" /chosen linux,initrd-end)" = "$(printf '%x' "$initrd_end")"
  if [[ ${dtb##*/} == pb626-elan-emmc-backup.dtb ]]; then
    test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = okay
    test "$(fdtget -t s "$dtb" /soc/mmc@1c0f000 status)" = disabled
    fdtget "$dtb" /chosen pb626,emmc-backup >/dev/null
  else
    test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = disabled
  fi
  test "$(fdtget -t x "$dtb" /backlight default-brightness-level)" = 0
done

sudo chown -R "$USER:$USER" dist
gzip -t dist/pb626-megi-initramfs.cpio.gz
gzip -cd dist/pb626-megi-initramfs.cpio.gz | cpio -t > dist/INITRAMFS-CONTENTS.txt 2>/dev/null
(grep -Fxq 'init' dist/INITRAMFS-CONTENTS.txt || grep -Fxq './init' dist/INITRAMFS-CONTENTS.txt)
grep -F '/rtl8188eufw.bin' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -Fxq 'kernel/drivers/video/fbdev/sun5i-eink.ko' "rootfs/lib/modules/$kernel_release/modules.builtin"
if grep -F '/sun5i-eink.ko' dist/INITRAMFS-CONTENTS.txt >/dev/null; then
  echo 'Unexpected loadable E Ink driver in built-in kernel bundle' >&2
  exit 1
fi
grep -F '/pb626-epd' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F '/rtl8xxxu.ko' dist/INITRAMFS-CONTENTS.txt >/dev/null
grep -F 'lib/modules/' dist/INITRAMFS-CONTENTS.txt >/dev/null
rm dist/INITRAMFS-CONTENTS.txt

cp scripts/{Start-PB626.ps1,fel-boot.sh} dist/
git rev-parse HEAD > dist/BUILD-COMMIT
(cd dist && sha256sum pb626-megi-zImage pb626-native-zImage *.dtb *.gz *.config KERNELRELEASE KERNEL-SOURCE.txt BUILD-COMMIT uapi/linux/sun5i-eink.h Start-PB626.ps1 fel-boot.sh > SHA256SUMS)
cat > dist/README.txt <<'NOTE'
PB626 ELAN/eMMC: elan-display is RAM-only; elan-emmc-backup is read-only recovery.
elan-emmc-native is for offline native image construction ONLY, never FEL RAM.
Use matching kernel, modules, DTB and checksums. See docs/INSTALL.md.
NOTE
test -s dist/pb626-megi-zImage
test -s dist/pb626-megi-initramfs.cpio.gz
test -s dist/KERNEL-SOURCE.txt
echo 'FULL RAM BUNDLE VERIFIED'
