#!/usr/bin/env bash
set -Eeuo pipefail

bundle=${1:?Verified FEL bundle}
base=${2:?Verified desktop base cache}
bridge=${3:?Display binary cache directory}
(cd "$bundle" && sha256sum -c SHA256SUMS)
(cd "$base" && sha256sum -c SHA256SUMS)
mkdir -p desktop-root fel-root dist "$bridge"
sudo tar --numeric-owner -xzf "$base/base.tar.gz" -C desktop-root
gzip -cd "$bundle/pb626-megi-initramfs.cpio.gz" |
  (cd fel-root && sudo cpio -id --quiet --no-absolute-filenames)

# The cached distribution root has no project files. Copy every project-owned
# input from the current FEL image, including modules and firmware.
sudo cp -a fel-root/lib/modules desktop-root/lib/
sudo install -m 644 fel-root/lib/firmware/rtlwifi/rtl8188eufw.bin desktop-root/lib/firmware/rtlwifi/rtl8188eufw.bin
sudo install -D -m 755 fel-root/init desktop-root/init
sudo install -d desktop-root/etc/pb626 desktop-root/sys/kernel/config desktop-root/dev/pts desktop-root/proc desktop-root/run
sudo chmod 700 desktop-root/etc/pb626
for file in inspect-pb626 probe-pb626 pb626-network; do
  sudo install -D -m 755 "fel-root/usr/sbin/$file" "desktop-root/usr/sbin/$file"
done
sudo install -m 644 fel-root/etc/pb626-image-id desktop-root/etc/pb626-image-id
sudo install -m 755 fel-root/usr/bin/pb626-epd desktop-root/usr/bin/pb626-epd

sudo install -m 755 /usr/bin/qemu-arm-static desktop-root/usr/bin/
test "$(/usr/bin/qemu-arm-static desktop-root/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-4
# A bridge cache must match the precise runtime package set, not just source.
sudo chroot desktop-root /usr/bin/qemu-arm-static /sbin/apk info -v | LC_ALL=C sort > /tmp/pb626-runtime-packages
if [[ -f "$bridge/SHA256SUMS" ]]; then
  (cd "$bridge" && sha256sum -c SHA256SUMS)
  cmp "$bridge/runtime-packages.txt" /tmp/pb626-runtime-packages
  sudo install -m 755 "$bridge/pb626-x11-epd" desktop-root/usr/bin/pb626-x11-epd
  cp "$bridge/native-worker" ./native-worker
else
sudo install -m 644 display/{pb626-x11-epd.c,test-pb626-x11-epd.c,pb626-epd.c,test-pb626-epd.c,pb626-epd.h} desktop-root/tmp/
sudo cp -r "$bundle/uapi" desktop-root/tmp/uapi
sudo cp /etc/resolv.conf desktop-root/etc/resolv.conf
sudo chroot desktop-root /usr/bin/qemu-arm-static /sbin/apk add --no-cache --virtual .pb626-bridge-build \
  build-base linux-headers libx11-dev libxext-dev libxtst-dev libxdamage-dev libxfixes-dev
sudo chroot desktop-root /usr/bin/qemu-arm-static /bin/sh -ec '
  cd /tmp
  cc -O2 -Wall -Wextra -Werror pb626-x11-epd.c -o /usr/bin/pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lm
  cc -O2 -Wall -Wextra -Werror test-pb626-x11-epd.c -o test-pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lm
  ./test-pb626-x11-epd
  strip /usr/bin/pb626-x11-epd
  cc -O3 -Wall -Wextra -Werror -I uapi pb626-epd.c -o /tmp/native-worker
  cc -O2 -Wall -Wextra -Werror -I uapi test-pb626-epd.c -o /tmp/test-native-worker
  /tmp/test-native-worker
  test "$(/tmp/native-worker --protocol)" = pb626-epd-shm-4
  strip /tmp/native-worker
  apk del .pb626-bridge-build
'
sudo chroot desktop-root /usr/bin/qemu-arm-static /sbin/apk info -v | LC_ALL=C sort > /tmp/pb626-runtime-after
if ! cmp -s /tmp/pb626-runtime-packages /tmp/pb626-runtime-after; then
  echo 'Desktop runtime packages changed while building the renderer; rebuild the desktop base rather than caching mismatched binaries.' >&2
  diff -u /tmp/pb626-runtime-packages /tmp/pb626-runtime-after || true
  exit 1
fi
sudo cp desktop-root/tmp/native-worker ./native-worker
sudo install -m 755 desktop-root/usr/bin/pb626-x11-epd "$bridge/pb626-x11-epd"
sudo install -m 755 ./native-worker "$bridge/native-worker"
sudo chown "$USER:$USER" "$bridge/pb626-x11-epd" "$bridge/native-worker"
cp /tmp/pb626-runtime-packages "$bridge/runtime-packages.txt"
(cd "$bridge" && sha256sum pb626-x11-epd native-worker runtime-packages.txt > SHA256SUMS)
fi
sudo install -m 755 ./native-worker desktop-root/tmp/native-worker
test "$(sudo chroot desktop-root /usr/bin/qemu-arm-static /tmp/native-worker --protocol)" = pb626-epd-shm-4
sudo chroot desktop-root /usr/bin/qemu-arm-static /lib/ld-musl-armhf.so.1 --list /usr/bin/pb626-x11-epd
sudo rm -rf desktop-root/tmp/{pb626-x11-epd.c,test-pb626-x11-epd.c,test-pb626-x11-epd,pb626-epd.c,test-pb626-epd.c,test-native-worker,native-worker,pb626-epd.h,uapi} desktop-root/usr/bin/qemu-arm-static
printf 'nameserver 1.1.1.1\n' | sudo tee desktop-root/etc/resolv.conf >/dev/null

sudo install -m 755 display/pb626-desktop display/pb626-xsession display/pb626-settings desktop-root/usr/bin/
sudo install -D -m 644 display/xorg.conf desktop-root/etc/pb626/xorg.conf
sudo install -D -m 644 display/eink-fonts.conf desktop-root/etc/fonts/conf.d/99-pb626-eink.conf
sudo install -D -m 644 display/matchbox/Xresources desktop-root/etc/X11/pb626.Xresources
sudo install -D -m 644 display/no-color.sh desktop-root/etc/profile.d/pb626-no-color.sh
sudo install -D -m 644 display/gtkrc desktop-root/etc/gtk-2.0/gtkrc
for version in 3 4; do
  sudo install -D -m 644 display/gtk-settings.ini "desktop-root/etc/gtk-$version.0/settings.ini"
done
test -x desktop-root/usr/bin/xrdb
sudo install -D -m 644 display/matchbox/keyboard.desktop desktop-root/etc/pb626/keyboard.desktop
sudo tic -x -o desktop-root/etc/terminfo display/matchbox/pb626-mono.terminfo
sudo install -d desktop-root/usr/share/themes/PB626/matchbox
sudo install -m 644 display/matchbox/PB626/* desktop-root/usr/share/themes/PB626/matchbox/
sudo install -d desktop-root/usr/share/matchbox/vfolders
sudo install -m 644 display/matchbox/{Root.order,*.directory} desktop-root/usr/share/matchbox/vfolders/
sudo install -m 644 display/matchbox/{xterm,htop,pb626-*}.desktop desktop-root/usr/share/applications/
sudo rm -f desktop-root/usr/share/applications/uxterm.desktop
test -x desktop-root/usr/bin/pb626-epd
test -x desktop-root/usr/bin/matchbox-desktop
# Leave at least 120 MiB for the kernel, display buffers and live applications.
size=$(sudo du -sm desktop-root | cut -f1)
echo "Unpacked desktop: $size MiB"
test "$size" -le 130
(cd desktop-root && sudo find . -print0 | sudo cpio --null -o -H newc --quiet) |
  gzip -3 > dist/pb626-desktop-root.cpio.gz

cp "$bundle"/{pb626-megi-initramfs.cpio.gz,pb626-megi-zImage,pb626-elan-display.dtb,KERNELRELEASE,BUILD-COMMIT} dist/
cp scripts/{Start-PB626.ps1,Start-PB626Desktop.ps1,fel-boot.sh} dist/
dtb=dist/pb626-elan-display.dtb
for mmc in 1c0f000 1c11000; do
  test "$(fdtget -t s "$dtb" "/soc/mmc@$mmc" status)" = disabled
done
(cd dist && sha256sum pb626-* KERNELRELEASE BUILD-COMMIT Start-PB626.ps1 Start-PB626Desktop.ps1 fel-boot.sh > SHA256SUMS)
# Build native root separately from the RAM archive.
mkdir -p native-dist
sudo install -m 755 ./native-worker desktop-root/usr/bin/pb626-epd
bash scripts/build-native-rootfs.sh desktop-root
printf 'pb626-native-alpine-openrc-v2\n' | sudo tee desktop-root/etc/pb626-image-id >/dev/null
sudo tar --numeric-owner -C desktop-root -czf native-dist/pb626-native-rootfs.tar.gz .
cp "$bundle"/{pb626-native-zImage,pb626-elan-emmc-native.dtb,KERNELRELEASE,KERNEL-SOURCE.txt} native-dist/
python3 BT0-uncaged/pack-kernel.py native-dist/pb626-native-zImage native-dist/pb626-elan-emmc-native.dtb native-dist/raw-linux.img
cp "$bundle/BUILD-COMMIT" native-dist/BUILD-COMMIT
test "$(cat native-dist/BUILD-COMMIT)" = "$(git rev-parse HEAD)"
(cd native-dist && sha256sum pb626-* KERNELRELEASE KERNEL-SOURCE.txt BUILD-COMMIT raw-linux.img > SHA256SUMS)
