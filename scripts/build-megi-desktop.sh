#!/usr/bin/env bash
set -Eeuo pipefail

bundle=${1:?Specify the verified FEL bundle directory}
(cd "$bundle" && sha256sum -c SHA256SUMS)
mkdir -p desktop-root dist
gzip -cd "$bundle/pb626-megi-initramfs.cpio.gz" |
  (cd desktop-root && sudo cpio -id --quiet --no-absolute-filenames)

fetch_source() {
  local project=$1 tag=$2 revision=$3
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
    "https://git.yoctoproject.org/$project" "$project"
  test "$(git -C "$project" rev-parse HEAD)" = "$revision"
  sudo cp -a "$project" desktop-root/tmp/
}
fetch_source libmatchbox 1.14 04b214a0d5cf8285e196d90bf2332626b12c74ef
fetch_source matchbox-window-manager 1.2.3 ce8c1053270d960a7235ab5c3435f707541810a4
sudo install -m 644 display/pb626-x11-epd.c desktop-root/tmp/
sudo install -m 755 /usr/bin/qemu-arm-static desktop-root/usr/bin/
sudo cp /etc/resolv.conf desktop-root/etc/resolv.conf

in_root() { sudo chroot desktop-root /usr/bin/qemu-arm-static "$@"; }
in_root /sbin/apk add --no-cache \
  xorg-server xf86-video-dummy xf86-input-evdev xinit xauth xset xsetroot xdotool \
  matchbox-keyboard libxft libpng libjpeg-turbo libxcursor libxfixes \
  font-liberation yad xterm xfe mousepad xcalc htop
in_root /sbin/apk add --no-cache --virtual .pb626-x-build \
  build-base autoconf automake libtool pkgconf libx11-dev libxext-dev libxft-dev \
  libxrender-dev libxcursor-dev libxfixes-dev libpng-dev libjpeg-turbo-dev expat-dev
in_root /bin/sh -e -c '
  cd /tmp/libmatchbox
  autoreconf -fi
  ./configure --prefix=/usr --disable-static
  make -j2
  make install
  cd /tmp/matchbox-window-manager
  autoreconf -fi
  ./configure --prefix=/usr --enable-expat --disable-xrm
  make -j2
  make install
  cd /tmp
  cc -O2 -Wall -Wextra -Werror pb626-x11-epd.c -o /usr/bin/pb626-x11-epd -lX11
  strip /usr/bin/pb626-x11-epd /usr/bin/matchbox-window-manager
'
in_root /sbin/apk del .pb626-x-build
in_root /lib/ld-musl-armhf.so.1 --list /usr/bin/matchbox-window-manager
in_root /usr/bin/Xorg -version
sudo rm -rf desktop-root/tmp/libmatchbox desktop-root/tmp/matchbox-window-manager
sudo rm -f desktop-root/tmp/pb626-x11-epd.c desktop-root/usr/bin/qemu-arm-static
printf 'nameserver 1.1.1.1\n' | sudo tee desktop-root/etc/resolv.conf >/dev/null

sudo install -m 755 display/pb626-desktop display/pb626-xsession desktop-root/usr/bin/
sudo install -D -m 644 display/xorg.conf desktop-root/etc/pb626/xorg.conf
test -x desktop-root/usr/bin/pb626-epd
# Leave at least 120 MiB for the kernel, display buffers and live applications.
test "$(sudo du -sm desktop-root | cut -f1)" -le 130
(cd desktop-root && sudo find . -print0 | sudo cpio --null -o -H newc --quiet) |
  gzip -3 > dist/pb626-megi-initramfs.cpio.gz

cp "$bundle"/{pb626-megi-zImage,pb626-elan-display.dtb,KERNELRELEASE} dist/
cp scripts/{Start-PB626.ps1,fel-boot.sh} dist/
dtb=dist/pb626-elan-display.dtb
for mmc in 1c0f000 1c11000; do
  test "$(fdtget -t s "$dtb" "/soc/mmc@$mmc" status)" = disabled
done
initrd_end=$((0x45000000 + $(stat -c %s dist/pb626-megi-initramfs.cpio.gz)))
test "$initrd_end" -lt $((0x50000000))
fdtput -t x "$dtb" /chosen linux,initrd-end "$(printf '%x' "$initrd_end")"
(cd dist && sha256sum pb626-* KERNELRELEASE > SHA256SUMS)
