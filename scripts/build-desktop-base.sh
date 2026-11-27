#!/usr/bin/env bash
# Build only distribution desktop packages. No kernel, DTB or project runtime
# enters this cache; those are installed from the current bundle.
set -Eeuo pipefail
alpine=${1:?Alpine base archive}
cache=${2:?Output cache directory}
mkdir -p "$cache" desktop-root
sudo tar --numeric-owner -xzf "$alpine" -C desktop-root

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
    libxfont2 pixman nettle libxcvt libpciaccess libxft harfbuzz libpng libjpeg-turbo libxcursor libxfixes libxrandr libfakekey \
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

build_userspace
sudo tar --numeric-owner -C desktop-root -czf "$cache/base.tar.gz" .
sudo chown "$USER:$USER" "$cache/base.tar.gz"
(cd "$cache" && sha256sum base.tar.gz > SHA256SUMS)
sudo rm -rf desktop-root
