#!/usr/bin/env bash
# Build a real Debian 13 armhf root on eMMC, independent of the Alpine RAM image.
# Run on a Linux x86_64 host with ARM binfmt, mmdebstrap and Debian archive keys.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
kernel=$(realpath "${1:?kernel-stage directory}")
out=$(realpath -m "${2:?output directory}")
test ! -e "$out" || { echo "Output already exists: $out" >&2; exit 1; }
work=$(mktemp -d)
chmod 755 "$work"
trap 'sudo rm -rf "$work"' EXIT
trap 'echo "Debian build failed at line $LINENO: $BASH_COMMAND" >&2' ERR
root="$work/root"
build="$work/build"
pkg="$work/pkg"
keys="$work/keys"
cd "$repo"

# Fail before the expensive foreign-architecture bootstrap if a host
# tool needed to package the final boot image is missing.
for tool in mmdebstrap clang ld.lld fdtget fdtput depmod tic git python3; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; exit 1; }
done

test -s "$kernel/pb626-megi-zImage"
test -s "$kernel/pb626-elan-emmc-native.dtb"
test -s "$kernel/kernel-modules.tar.gz"
test -s "$kernel/uapi/linux/sun5i-eink.h"
bash scripts/configure-megi-kernel.sh --check "$kernel/pb626-megi.config"
release=$(cat "$kernel/KERNELRELEASE")
test -n "$release"
fdtget "$kernel/pb626-elan-emmc-native.dtb" /chosen pb626,emmc-root >/dev/null
test "$(fdtget -t s "$kernel/pb626-elan-emmc-native.dtb" /soc/mmc@1c11000 status)" = okay
test "$(fdtget -t s "$kernel/pb626-elan-emmc-native.dtb" /soc/mmc@1c0f000 status)" = disabled

# Noble's packaged archive keyring predates Trixie. Obtain the updated
# keyring from signed Bookworm metadata, never disable signature checks.
sudo mmdebstrap --mode=root --variant=extract --architectures=amd64 \
  --include=debian-archive-keyring \
  --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
  bookworm "$keys" "deb http://deb.debian.org/debian bookworm main"
keyring="$keys/usr/share/keyrings/debian-archive-keyring.gpg"
test -s "$keyring"

# No full desktop task, display manager, NetworkManager, or recommended
# packages. All ordinary programs remain managed by dpkg/APT.
runtime=(
  systemd-sysv systemd-resolved systemd-timesyncd systemd-zram-generator udev
  dbus dbus-user-session libpam-systemd opendoas ca-certificates tzdata
  iproute2 iw iwd iwgtk rfkill wireless-regdb firmware-realtek nftables
  kmod procps psmisc util-linux util-linux-extra e2fsprogs usbutils i2c-tools
  lm-sensors v4l-utils curl openssh-server nano htop mc xidle
  xserver-xorg-core xserver-xorg-video-dummy xserver-xorg-input-evdev
  xinit xauth x11-xserver-utils x11-utils x11-apps x11-xkb-utils xkb-data xrestop
  xfonts-base xfonts-utils xbitmaps fonts-liberation xdotool xterm nedit
  matchbox-window-manager matchbox-desktop matchbox-keyboard matchbox-panel
  matchbox-common libmatchbox1 tk python3-tk python3-pil.imagetk mupdf
  libx11-6 libxext6 libxtst6 libxdamage1 libxfixes3 libxrandr2
)
includes=$(IFS=,; echo "${runtime[*]}")
sudo env DEBIAN_FRONTEND=noninteractive mmdebstrap \
  --mode=root --variant=minbase --architectures=armhf \
  --include="$includes" --keyring="$keyring" \
  --aptopt='APT::Install-Recommends "false";' \
  --aptopt='APT::Install-Suggests "false";' \
  --aptopt='Acquire::Languages "none";' \
  trixie "$root" \
  "deb http://deb.debian.org/debian trixie main non-free-firmware" \
  "deb http://deb.debian.org/debian trixie-updates main non-free-firmware" \
  "deb http://deb.debian.org/debian-security trixie-security main non-free-firmware"

in_root() { sudo chroot "$root" "$@"; }
in_build() { sudo chroot "$build" "$@"; }
test "$(in_root dpkg --print-architecture)" = armhf
in_root grep -qx 'VERSION_CODENAME=trixie' /etc/os-release
# Use target-owned Debian archive keyring for future APT operations.
sudo rm -f "$root/etc/apt/sources.list"
sudo install -d "$root/etc/apt/sources.list.d"
sudo tee "$root/etc/apt/sources.list.d/debian.sources" >/dev/null <<'SOURCES'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://deb.debian.org/debian-security
Suites: trixie-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES
# Some mmdebstrap versions generate an additional legacy list. Remove only
# bootstrap-managed files; the single Debian sources file is authoritative.
sudo find "$root/etc/apt/sources.list.d" -maxdepth 1 -type f ! -name debian.sources -delete
sudo rm -f "$root/etc/resolv.conf"
sudo cp -L /etc/resolv.conf "$root/etc/resolv.conf"
sudo tee "$root/usr/sbin/policy-rc.d" >/dev/null <<'POLICY'
#!/bin/sh
exit 101
POLICY
sudo chmod 755 "$root/usr/sbin/policy-rc.d"

# A disposable build chroot prevents development dependencies, compiler
# packages and temporary files from leaking into the device rootfs.
sudo mkdir "$build"
sudo cp -a "$root/." "$build/"
in_build apt-get update
in_build env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential autoconf automake libtool pkg-config gettext autopoint intltool \
  libx11-dev libxext-dev libxft-dev libxrender-dev libxcursor-dev libxfixes-dev \
  libxtst-dev libxdamage-dev libxrandr-dev libpng-dev libjpeg-dev libexpat1-dev libfakekey-dev \
  libmatchbox-dev libstartup-notification0-dev libcairo2-dev
sudo install -d "$build/tmp/pb626-build" "$pkg/usr/bin" "$pkg/usr/libexec/pb626/bin"
sudo install -m 644 display/{pb626-epd.c,pb626-epd.h,pb626-sleep.h,pb626-ddx-fb.h,pb626-x11-epd.c,test-pb626-epd.c,test-pb626-x11-epd.c} "$build/tmp/pb626-build/"
sudo cp -a "$kernel/uapi" "$build/tmp/pb626-build/uapi"
sudo install -m 644 display/{matchbox-keyboard-eink.patch,matchbox-panel-power-supply.patch} "$build/tmp/pb626-build/"

fetch_source() {
    local name=$1 rev=$2 src="$work/src-$1"
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 "https://git.yoctoproject.org/$name" "$rev"
    git -C "$src" checkout -q --detach FETCH_HEAD
    test "$(git -C "$src" rev-parse HEAD)" = "$rev"
    sudo mkdir "$build/tmp/pb626-build/$name"
    git -C "$src" archive HEAD | sudo tar -xf - -C "$build/tmp/pb626-build/$name"
}
fetch_source matchbox-keyboard 630d89068dc0a1e9199306d405cb32f892dfa4d3
fetch_source matchbox-panel 886605280c1032f76e382f68f9a1d2e57012f4db

in_build /bin/bash -euc '
  cd /tmp/pb626-build
  cc -O3 -Wall -Wextra -Werror -I uapi pb626-epd.c -o pb626-epd
  cc -mfpu=neon -O2 -Wall -Wextra -Werror pb626-x11-epd.c -o pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lXrandr -lm
  cc -O2 -Wall -Wextra -Werror -I uapi test-pb626-epd.c -o test-pb626-epd
  cc -mfpu=neon -O2 -Wall -Wextra -Werror test-pb626-x11-epd.c -o test-pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lXrandr -lm
  ./test-pb626-epd
  ./test-pb626-x11-epd
  test "$(./pb626-epd --protocol)" = pb626-epd-shm-4
  strip pb626-epd pb626-x11-epd
  export CFLAGS="-O2 -std=gnu17"
  cd matchbox-keyboard
  patch -p1 < ../matchbox-keyboard-eink.patch
  autoreconf -fi
  ./configure --prefix=/usr --sysconfdir=/etc --disable-shared --enable-static
  make -j2
  make install DESTDIR=/tmp/pb626-build/keyboard-install
  cd ../matchbox-panel
  patch -l -p1 < ../matchbox-panel-power-supply.patch
  autoreconf -fi
  # Old Matchbox relies on libmatchbox transitive X11 dependencies.
  LIBS="$(pkg-config --libs x11 xext xrender xft)" \
    ./configure --prefix=/usr --sysconfdir=/etc --enable-linux-power-supply
  make -j2
  make install DESTDIR=/tmp/pb626-build/panel-install
  strip /tmp/pb626-build/keyboard-install/usr/bin/matchbox-keyboard \
        /tmp/pb626-build/panel-install/usr/bin/matchbox-panel \
        /tmp/pb626-build/panel-install/usr/bin/mb-applet-battery
'
built="$build/tmp/pb626-build"
sudo install -m 755 "$built"/{pb626-epd,pb626-x11-epd} "$pkg/usr/bin/"
sudo install -m 755 "$built/keyboard-install/usr/bin/matchbox-keyboard" \
  "$built/panel-install/usr/bin/matchbox-panel" \
  "$built/panel-install/usr/bin/mb-applet-battery" "$pkg/usr/libexec/pb626/bin/"
# Keep the exact patched client binaries in a private PATH; Debian owns its
# normal Matchbox packages, data, libraries and unaffected applets.
sudo cp -a boot/debian/rootfs/usr/. "$pkg/usr/"
sudo install -D -m 755 boot/debian/pb626-admin "$pkg/usr/sbin/pb626-admin"
sudo install -D -m 755 boot/debian/pb626-user-session "$pkg/usr/libexec/pb626-user-session"
sudo install -D -m 755 boot/pb626-native-desktop "$pkg/usr/sbin/pb626-native-desktop"
sudo install -D -m 755 boot/native/pb626-usb "$pkg/usr/libexec/pb626-usb"
sudo install -D -m 755 scripts/profile-memory.sh "$pkg/usr/sbin/pb626-profile-memory"
sudo install -D -m 755 scripts/inspect-live.sh "$pkg/usr/sbin/inspect-pb626"
sudo install -D -m 755 scripts/probe-device.sh "$pkg/usr/sbin/probe-pb626"
sudo install -m 755 display/pb626-open-document display/pb626-shutdown-picker "$pkg/usr/bin/"
sed '1s|^#!/bin/sh$|#!/bin/bash|' display/pb626-desktop | sudo tee "$pkg/usr/bin/pb626-desktop" >/dev/null
sudo chmod 755 "$pkg/usr/bin/pb626-desktop"
sudo install -m 755 display/pb626-debian-settings "$pkg/usr/bin/pb626-control-center"
# Debian /bin/sh is dash; the existing X11 session uses wait -n.
sed '1s|^#!/bin/sh$|#!/bin/bash|' display/pb626-xsession | sudo tee "$pkg/usr/bin/pb626-xsession" >/dev/null
sudo chmod 755 "$pkg/usr/bin/pb626-xsession"
sudo install -D -m 644 display/xorg-debian.conf "$pkg/etc/pb626/xorg.conf"
sudo install -D -m 644 display/matchbox/keyboard.desktop "$pkg/etc/pb626/keyboard.desktop"
sudo install -D -m 644 display/matchbox/Xresources "$pkg/etc/X11/pb626.Xresources"
sudo install -D -m 644 display/eink-fonts.conf "$pkg/etc/fonts/conf.d/99-pb626-eink.conf"
sudo install -D -m 644 display/no-color.sh "$pkg/etc/profile.d/pb626-no-color.sh"
sudo install -d "$pkg/usr/share/themes/PB626/matchbox" "$pkg/usr/share/applications"
sudo install -m 644 display/matchbox/PB626/* "$pkg/usr/share/themes/PB626/matchbox/"
sudo install -m 644 display/matchbox/{pb626-calculator,pb626-editor,pb626-files}.desktop "$pkg/usr/share/applications/"
sudo install -m 644 display/native/*.desktop "$pkg/usr/share/applications/"
sudo install -m 644 display/matchbox/htop.desktop "$pkg/usr/share/applications/pb626-monitor.desktop"
sudo tic -x -o "$pkg/etc/terminfo" display/matchbox/pb626-mono.terminfo

# dpkg owns all project executables and units; hardware-specific config
# is applied as local administrator policy below, not by overwriting
# package-owned executables. The .deb is also emitted for local upgrades.
sudo install -d "$pkg/DEBIAN"
version="0.1+$(git rev-parse --short=12 HEAD)"
sudo tee "$pkg/DEBIAN/control" >/dev/null <<CONTROL
Package: pb626-runtime
Version: $version
Architecture: armhf
Maintainer: BlackF1re <55582873+BlackF1re@users.noreply.github.com>
Depends: libc6, bash, systemd, dbus, opendoas, util-linux, xinit, xauth, x11-xserver-utils, xserver-xorg-core, xserver-xorg-video-dummy, xserver-xorg-input-evdev, matchbox-window-manager, matchbox-desktop, matchbox-keyboard, matchbox-panel, matchbox-common, libmatchbox1, libx11-6, libxext6, libxtst6, libxdamage1, libxfixes3, libxrandr2, tk, python3-tk, python3-pil.imagetk, mupdf, xterm, htop, mc, nedit, x11-apps, iwd, iwgtk, rfkill, xidle
Description: PocketBook 626 native E Ink desktop and hardware integration
 Includes the scanout worker, X11 bridge, patched Matchbox clients and
 board-specific systemd services. Uses the paired PB626 kernel and DTB.
CONTROL
(cd "$pkg" && sudo find etc -type f -printf '/%p\n' | LC_ALL=C sort) | sudo tee "$pkg/DEBIAN/conffiles" >/dev/null
sudo install -d "$pkg/usr/share/doc/pb626-runtime"
sudo install -m 644 LICENSE "$pkg/usr/share/doc/pb626-runtime/copyright"
sudo dpkg-deb --root-owner-group --build "$pkg" "$work/pb626-runtime.deb"
sudo install -m 644 "$work/pb626-runtime.deb" "$root/tmp/pb626-runtime.deb"
in_root dpkg -i /tmp/pb626-runtime.deb
sudo rm "$root/tmp/pb626-runtime.deb"

# Merge /usr correctly: don't extract a lib/ directory over Debian's
# /lib symlink. Modules are kept paired with this raw boot image.
sudo mkdir "$work/modules"
sudo tar --numeric-owner -xzf "$kernel/kernel-modules.tar.gz" -C "$work/modules"
sudo install -d "$root/usr/lib/modules" "$root/usr/lib/firmware/pb626"
sudo cp -a "$work/modules/lib/modules/." "$root/usr/lib/modules/"
sudo rm -f "$root/usr/lib/modules/$release"/{build,source}
sudo depmod -b "$root" "$release"
test -s "$root/usr/lib/modules/$release/modules.dep"
in_root test -s /lib/firmware/rtlwifi/rtl8188eufw.bin
# Factory waveform remains owner-supplied at offline installation.
# Trixie uses /etc/locale.conf; /etc/default/locale is a compatibility
# symlink and must never be overwritten from outside the chroot.
sudo cp -r boot/debian/rootfs/etc/. "$root/etc/"
in_root grep -qx "LANG=C.UTF-8" /etc/locale.conf
in_root grep -qx "LANG=C.UTF-8" /etc/default/locale
sudo install -m 600 boot/native/doas.conf "$root/etc/doas.conf"
sudo install -m 644 boot/native/fstab "$root/etc/fstab"
sudo install -m 600 boot/native/sshd_config "$root/etc/ssh/sshd_config"
sudo install -D -m 644 display/gtkrc "$root/etc/gtk-2.0/gtkrc"
for v in 3 4; do sudo install -D -m 644 display/gtk-settings.ini "$root/etc/gtk-$v.0/settings.ini"; done
# Preserve the current launcher organization where the stock package has
# different defaults. These are local settings, not executable replacements.
sudo install -d "$root/etc/matchbox/vfolders"
sudo install -m 644 display/matchbox/{Root.order,*.directory} "$root/etc/matchbox/vfolders/"
printf 'pb626\n' | sudo tee "$root/etc/hostname" >/dev/null
printf '127.0.0.1 localhost pb626\n::1 localhost\n' | sudo tee "$root/etc/hosts" >/dev/null
printf 'pb626-native-debian13-armhf-v1\n' | sudo tee "$root/etc/pb626-image-id" >/dev/null
sudo ln -snf /usr/share/zoneinfo/UTC "$root/etc/localtime"
printf 'UTC\n' | sudo tee "$root/etc/timezone" >/dev/null
in_root groupadd -f netdev
in_root useradd -m -u 1000 -U -G netdev -s /bin/bash reader
in_root passwd -l reader
in_root passwd -l root
sudo install -d -m 755 -o 1000 -g 1000 "$root/home/reader/"{Books,Documents,Downloads}
sudo install -d -m 700 "$root/var/lib/pb626"
sudo install -d "$root/var/log/journal"

# Offline systemctl changes unit links, never runs a daemon in the chroot.
ctl() { sudo systemctl --root="$root" "$@"; }
ctl set-default multi-user.target
ctl enable pb626-board.service pb626-desktop.service pb626-usb.service pb626-battery.timer pb626-poweroff-screen.service \
  systemd-resolved.service systemd-timesyncd.service
# iwd starts on demand; user can enable it persistently from Settings.
# D-Bus activation is permitted for the normal iwgtk/iwctl clients.
for unit in iwd.service ssh.service ssh.socket nftables.service \
  apt-daily.timer apt-daily-upgrade.timer man-db.timer e2scrub_all.timer e2scrub_reap.service \
  systemd-networkd.service \
  systemd-networkd.socket systemd-networkd-wait-online.service getty@tty1.service; do
  if ctl is-enabled "$unit" >/dev/null 2>&1; then ctl disable "$unit"; fi
done
ctl mask tmp.mount systemd-backlight@.service
sudo rm -f "$root/etc/resolv.conf"
sudo ln -s /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
# A fresh unique machine ID and SSH keys must be generated on the device.
sudo truncate -s 0 "$root/etc/machine-id"
sudo rm -f "$root/var/lib/dbus/machine-id"
sudo ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
sudo rm -f "$root/etc/ssh"/ssh_host_* "$root/usr/sbin/policy-rc.d"
sudo rm -rf "$root/var/lib/apt/lists/"*
in_root apt-get clean
sudo chmod 1777 "$root/tmp"
test "$(sudo stat -c '%a:%u:%g' "$root/usr/bin/doas")" = 4755:0:0

# ARM-side checks verify real target loader, package state and privilege
# metadata rather than accidentally resolving host paths.
in_root /bin/bash -euc '
  test "$(dpkg --print-architecture)" = armhf
  dpkg -s pb626-runtime | grep -qx "Status: install ok installed"
  test -z "$(dpkg --audit)"
  test -x /sbin/init
  test "$(readlink -f /sbin/init)" = /usr/lib/systemd/systemd
  test "$(id -u reader)" = 1000
  id -nG reader | grep -qw netdev
  test "$(runuser -u reader -- id -u)" = 1000
  awk -F: '\''($1=="root" || $1=="reader") && $2 ~ /^[!*]/ {n++} END {exit n!=2}'\'' /etc/shadow
  test "$(/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-4
  bash -n /usr/bin/pb626-xsession
  sh -n /usr/sbin/pb626-admin
  for exe in /usr/bin/pb626-epd /usr/bin/pb626-x11-epd /usr/libexec/pb626/bin/*; do
    ldd "$exe" > /tmp/pb626-ldd
    cat /tmp/pb626-ldd
    if grep -q "not found" /tmp/pb626-ldd; then
      echo "Unresolved runtime library: $exe" >&2
      exit 1
    fi
  done
  rm /tmp/pb626-ldd
  test -x /usr/lib/xorg/Xorg || test -x /usr/bin/Xorg
  for exe in iwgtk iwctl systemctl systemd-run wish mupdf xterm matchbox-desktop xrestop xidle; do command -v "$exe"; done
  for unexpected in apk gcc; do
    if command -v "$unexpected" >/dev/null; then
      echo "Unexpected executable in Debian rootfs: $unexpected" >&2
      exit 1
    fi
  done
  test -x /usr/bin/dbus-run-session
'
for unit in pb626-board.service pb626-desktop.service pb626-usb.service systemd-resolved.service; do
  test "$(ctl is-enabled "$unit")" = enabled
done
for unit in iwd.service man-db.timer e2scrub_all.timer e2scrub_reap.service; do
  test "$(ctl is-enabled "$unit" || :)" = disabled
done
test "$(ctl is-enabled tmp.mount || :)" = masked
test ! -e "$root/usr/bin/qemu-arm-static"
sudo install -m 644 tests/check-control-center.tcl "$root/tmp/pb626-check-tk.tcl"
in_root tclsh /tmp/pb626-check-tk.tcl /usr/bin/pb626-control-center /usr/bin/pb626-open-document
sudo rm "$root/tmp/pb626-check-tk.tcl"

mkdir -p "$out"
in_root dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort > "$out/DEBIAN-PACKAGES.txt"
sudo tar --numeric-owner -C "$root" -czf "$out/pb626-native-rootfs.tar.gz" .
sudo install -m 644 "$work/pb626-runtime.deb" "$out/pb626-runtime_armhf.deb"
cp "$kernel/pb626-megi-zImage" "$out/pb626-native-zImage"
cp "$kernel/"{pb626-elan-emmc-native.dtb,KERNELRELEASE,KERNEL-SOURCE.txt,pb626-megi.config} "$out/"
python3 BT0-uncaged/pack-kernel.py "$out/pb626-native-zImage" "$out/pb626-elan-emmc-native.dtb" "$out/raw-linux.img"
# Optional native-only SD qualification image. Preserve the original DTB,
# eMMC alias/root path and all independent FEL safety contracts.
sd_dtb="$out/pb626-elan-emmc-native-sd.dtb"
cp "$out/pb626-elan-emmc-native.dtb" "$sd_dtb"
sd_node=/soc/mmc@1c0f000
fdtput -t s "$sd_dtb" "$sd_node" status okay
fdtput -t u "$sd_dtb" "$sd_node" max-frequency 12500000
# Conservative, experimental power-settling interval, not a measured value.
fdtput -t u "$sd_dtb" /regulator-mmc0 startup-delay-us 20000
for prop in no-1-8-v disable-wp no-mmc no-sdio; do
    fdtput "$sd_dtb" "$sd_node" "$prop"
done
test "$(fdtget -t u "$sd_dtb" "$sd_node" bus-width)" = 4
test "$(fdtget -t u "$sd_dtb" "$sd_node" max-frequency)" = 12500000
test "$(fdtget -t s "$sd_dtb" /soc/mmc@1c11000 status)" = okay
fdtget "$sd_dtb" "$sd_node" cd-gpios >/dev/null
fdtget "$sd_dtb" "$sd_node" vmmc-supply >/dev/null
python3 BT0-uncaged/pack-kernel.py "$out/pb626-native-zImage" "$sd_dtb" "$out/pb626-raw-linux-sd.img"
git rev-parse HEAD > "$out/BUILD-COMMIT"
(cd "$out" && sha256sum pb626-* KERNELRELEASE KERNEL-SOURCE.txt BUILD-COMMIT raw-linux.img DEBIAN-PACKAGES.txt > SHA256SUMS)
echo "Debian 13 armhf rootfs (on eMMC): $(sudo du -sm "$root" | cut -f1) MiB"
