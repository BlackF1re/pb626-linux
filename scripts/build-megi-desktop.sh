#!/usr/bin/env bash
set -Eeuo pipefail

bundle=${1:?Specify the verified FEL bundle directory}
previous=${2:-}
(cd "$bundle" && sha256sum -c SHA256SUMS)
mkdir -p desktop-root dist
gzip -cd "$bundle/pb626-megi-initramfs.cpio.gz" |
  (cd desktop-root && sudo cpio -id --quiet --no-absolute-filenames)

build_userspace() {
  local xorg_package
  fetch_source() {
    local project=$1 revision=$2
    git init -q "$project"
    git -C "$project" fetch -q --depth 1 "https://git.yoctoproject.org/$project" "$revision"
    git -C "$project" checkout -q --detach FETCH_HEAD
    sudo cp -a "$project" desktop-root/tmp/
  }
  fetch_source libmatchbox 04b214a0d5cf8285e196d90bf2332626b12c74ef
  fetch_source matchbox-window-manager ce8c1053270d960a7235ab5c3435f707541810a4
  fetch_source matchbox-keyboard 630d89068dc0a1e9199306d405cb32f892dfa4d3
  fetch_source matchbox-desktop b7e5fd6f08c046505615ce992e379bea9531e39d
  fetch_source matchbox-panel 886605280c1032f76e382f68f9a1d2e57012f4db
  fetch_source matchbox-common 3055fb158054d059e9a50141e7ded2a41ecfbd47
  sudo install -m 644 display/{matchbox-keyboard-eink.patch,matchbox-panel-power-supply.patch} desktop-root/tmp/
  sudo install -m 755 /usr/bin/qemu-arm-static desktop-root/usr/bin/
  sudo cp /etc/resolv.conf desktop-root/etc/resolv.conf

  in_root() { sudo chroot desktop-root /usr/bin/qemu-arm-static "$@"; }
  in_root /sbin/apk add --no-cache \
    xf86-video-dummy xf86-input-evdev xinit xauth xset xsetroot xdotool libxtst libxdamage \
    libxfont2 pixman nettle libxcvt libpciaccess libxft harfbuzz libpng libjpeg-turbo libxcursor libxfixes libfakekey \
    xorg-server-common libxau libxdmcp libxshmfence libdrm eudev-libs \
    xkbcomp xkeyboard-config font-misc-misc font-cursor-misc font-liberation \
    xterm mc nedit xcalc htop
  # The dummy driver uses the core Xorg executable without the Mesa-backed modules.
  in_root /sbin/apk fetch --no-cache --output /tmp xorg-server
  in_root /bin/sh -ec 'apk verify /tmp/xorg-server-*.apk'
  xorg_package=$(mktemp -d)
  sudo tar --ignore-zeros --warning=no-unknown-keyword -xzf desktop-root/tmp/xorg-server-*.apk \
    -C "$xorg_package" usr/libexec/Xorg
  sudo install -m 755 "$xorg_package/usr/libexec/Xorg" desktop-root/usr/bin/Xorg
  sudo rm -rf "$xorg_package"
  sudo rm -f desktop-root/tmp/xorg-server-*.apk
  in_root /sbin/apk add --no-cache --virtual .pb626-x-build \
    build-base linux-headers autoconf automake libtool pkgconf libx11-dev libxext-dev libxft-dev \
    libxrender-dev libxcursor-dev libxfixes-dev libxtst-dev libxdamage-dev \
    libpng-dev libjpeg-turbo-dev expat-dev libfakekey-dev
  in_root /bin/sh -e -c '
  rm -f /usr/share/X11/xorg.conf.d/10-evdev.conf
  mkdir -p /var/lib/xkb
  export CFLAGS="-O2 -std=gnu17"
  cd /tmp/libmatchbox
  autoreconf -fi
  ./configure --prefix=/usr --disable-static
  make -j2
  make install
  cd /tmp/matchbox-window-manager
  sed -i "s/^AM_GCONF_SOURCE_2$/AM_CONDITIONAL([GCONF_SCHEMAS_INSTALL], [false])/" configure.ac
  autoreconf -fi
  ./configure --prefix=/usr --enable-expat --disable-xrm
  make -j2
  make install
  cd /tmp/matchbox-keyboard
  patch -p1 < /tmp/matchbox-keyboard-eink.patch
  autoreconf -fi
  ./configure --prefix=/usr
  make -j2
  make install
  cd /tmp/matchbox-desktop
  autoreconf -fi
  ./configure --prefix=/usr --sysconfdir=/etc --disable-static
  make -j2
  make install
  cd /tmp/matchbox-panel
  patch -l -p1 < /tmp/matchbox-panel-power-supply.patch
  autoreconf -fi
  ./configure --prefix=/usr --enable-linux-power-supply
  make -j2
  make install
  cp /tmp/matchbox-common/icons/*.png /tmp/matchbox-common/icons/*.xpm /usr/share/pixmaps/
  strip /usr/bin/matchbox-window-manager /usr/bin/matchbox-keyboard \
    /usr/bin/matchbox-desktop /usr/bin/matchbox-panel /usr/bin/mb-applet-battery \
    /usr/lib/matchbox/desktop/*.so
  '
  in_root /sbin/apk del .pb626-x-build
  in_root /lib/ld-musl-armhf.so.1 --list /usr/bin/matchbox-window-manager
  in_root /lib/ld-musl-armhf.so.1 --list /usr/bin/matchbox-keyboard
  in_root /lib/ld-musl-armhf.so.1 --list /usr/bin/matchbox-desktop
  in_root /lib/ld-musl-armhf.so.1 --list /usr/bin/matchbox-panel
  in_root /lib/ld-musl-armhf.so.1 --list /usr/bin/mb-applet-battery
  in_root /usr/bin/Xorg -version
  sudo rm -rf desktop-root/tmp/libmatchbox \
    desktop-root/tmp/matchbox-window-manager desktop-root/tmp/matchbox-keyboard \
    desktop-root/tmp/matchbox-desktop desktop-root/tmp/matchbox-panel desktop-root/tmp/matchbox-common
  sudo rm -f desktop-root/tmp/{matchbox-keyboard-eink.patch,matchbox-panel-power-supply.patch} \
    desktop-root/usr/bin/qemu-arm-static
  printf 'nameserver 1.1.1.1\n' | sudo tee desktop-root/etc/resolv.conf >/dev/null
}

if [[ -n $previous ]]; then
  (cd "$previous" && sha256sum -c SHA256SUMS)
  mv desktop-root fel-root
  mkdir desktop-root
  archive="$previous/pb626-desktop-root.cpio.gz"
  if [[ ! -f $archive ]]; then
    archive="$previous/pb626-megi-initramfs.cpio.gz"
  fi
  gzip -cd "$archive" |
    (cd desktop-root && sudo cpio -id --quiet --no-absolute-filenames)
  sudo rm -rf desktop-root/lib/modules
  sudo cp -a fel-root/lib/modules desktop-root/lib/
  sudo install -m 755 fel-root/usr/bin/pb626-epd desktop-root/usr/bin/
else
  build_userspace
fi

# Always rebuild the bridge, even when reusing a previous desktop rootfs.
sudo install -m 755 /usr/bin/qemu-arm-static desktop-root/usr/bin/
test "$(/usr/bin/qemu-arm-static desktop-root/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-4
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
sudo cp desktop-root/tmp/native-worker ./native-worker
sudo rm -rf desktop-root/tmp/{pb626-x11-epd.c,test-pb626-x11-epd.c,test-pb626-x11-epd,pb626-epd.c,test-pb626-epd.c,test-native-worker,native-worker,pb626-epd.h,uapi} desktop-root/usr/bin/qemu-arm-static
printf 'nameserver 1.1.1.1\n' | sudo tee desktop-root/etc/resolv.conf >/dev/null

sudo install -m 755 display/pb626-desktop display/pb626-xsession desktop-root/usr/bin/
sudo install -D -m 644 display/xorg.conf desktop-root/etc/pb626/xorg.conf
sudo install -D -m 644 display/eink-fonts.conf desktop-root/etc/fonts/conf.d/99-pb626-eink.conf
sudo install -D -m 644 display/matchbox/Xresources desktop-root/etc/pb626/Xresources
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

cp "$bundle"/{pb626-megi-initramfs.cpio.gz,pb626-megi-zImage,pb626-elan-display.dtb,KERNELRELEASE} dist/
cp scripts/{Start-PB626.ps1,Start-PB626Desktop.ps1,fel-boot.sh} dist/
dtb=dist/pb626-elan-display.dtb
for mmc in 1c0f000 1c11000; do
  test "$(fdtget -t s "$dtb" "/soc/mmc@$mmc" status)" = disabled
done
(cd dist && sha256sum pb626-* KERNELRELEASE > SHA256SUMS)
# Build native root separately from the RAM archive.
mkdir -p native-dist
sudo install -m 755 ./native-worker desktop-root/usr/bin/pb626-epd
sudo install -m 755 boot/pb626-native-{setup,desktop,console} desktop-root/sbin/
sudo install -m 644 boot/pb626-native.inittab desktop-root/etc/inittab
printf 'pb626-native-alpine-v1\n' | sudo tee desktop-root/etc/pb626-image-id >/dev/null
sudo rm -f desktop-root/init
sudo tar --numeric-owner -C desktop-root -czf native-dist/pb626-native-rootfs.tar.gz .
cp "$bundle"/{pb626-native-zImage,pb626-elan-emmc-native.dtb,KERNELRELEASE,KERNEL-SOURCE.txt} native-dist/
python3 BT0-uncaged/pack-kernel.py native-dist/pb626-native-zImage native-dist/pb626-elan-emmc-native.dtb native-dist/raw-linux.img
git rev-parse HEAD > native-dist/BUILD-COMMIT
(cd native-dist && sha256sum pb626-* KERNELRELEASE KERNEL-SOURCE.txt BUILD-COMMIT raw-linux.img > SHA256SUMS)
