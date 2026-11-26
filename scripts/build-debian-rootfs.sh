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

# Reuse a validated independent Debian base, or build it for local use.
base=${3:-"$work/debian-base"}
if [ "$#" -lt 3 ]; then bash scripts/build-debian-base.sh "$base"; fi
(cd "$base" && sha256sum -c SHA256SUMS)
sudo tar --numeric-owner --acls --xattrs -xzf "$base/debian-chroots.tar.gz" -C "$work"
for d in "$root" "$build"; do
    sudo cp -L /etc/resolv.conf "$d/etc/resolv.conf"
done
in_root() { sudo chroot "$root" "$@"; }
in_build() { sudo chroot "$build" "$@"; }
test "$(in_root dpkg --print-architecture)" = armhf
in_root grep -qx 'VERSION_CODENAME=trixie' /etc/os-release

# The cache contains only the tested target executables and required license
# files. Package assembly always runs against the current checkout.
compiled_cache=${4:-"$work/compiled-cache"}
mkdir -p "$pkg/usr/bin" "$pkg/usr/libexec/pb626/bin"
sudo install -d "$build/tmp/pb626-build"
if [ -f "$compiled_cache/SHA256SUMS" ]; then
    (cd "$compiled_cache" && sha256sum -c SHA256SUMS)
    sudo tar --numeric-owner -xzf "$compiled_cache/compiled.tar.gz" -C "$build/tmp/pb626-build"
else
sudo install -d "$build/tmp/pb626-build" "$pkg/usr/bin" "$pkg/usr/libexec/pb626/bin"
sudo install -m 644 display/{pb626-epd.c,pb626-epd.h,pb626-sleep.h,pb626-ddx-fb.h,pb626-x11-epd.c,test-pb626-epd.c,test-pb626-x11-epd.c} "$build/tmp/pb626-build/"
sudo cp -a "$kernel/uapi" "$build/tmp/pb626-build/uapi"
sudo install -m 644 boot/debian/pb626-charge.c "$build/tmp/pb626-build/"
sudo install -m 644 display/{matchbox-keyboard-eink.patch,matchbox-panel-power-supply.patch,xorg-dummy-pb626-shared.patch} "$build/tmp/pb626-build/"

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
  cc -O2 -Wall -Wextra -Werror pb626-charge.c -o pb626-charge
  ./pb626-charge --self-test
  strip pb626-charge
  test "$(./pb626-epd --protocol)" = pb626-epd-shm-4
  strip pb626-epd pb626-x11-epd
  # Build against the actual target Xorg module ABI. The vendor package is
  # retained unmodified, and the private module is not selected by default.
  apt-get source --only-source xserver-xorg-video-dummy=1:0.4.0-1
  cd xserver-xorg-video-dummy-0.4.0
  cp ../pb626-ddx-fb.h src/
  patch --fuzz=0 -p1 < ../xorg-dummy-pb626-shared.patch
  autoreconf -fi
  ./configure --prefix=/usr
  make -j2
  test -s src/.libs/dummy_drv.so
  strip --strip-unneeded src/.libs/dummy_drv.so
  cd ..
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
    mkdir -p "$compiled_cache"
    sudo tar --numeric-owner -C "$build/tmp/pb626-build" -czf "$compiled_cache/compiled.tar.gz" \
        pb626-epd pb626-x11-epd pb626-charge \
        xserver-xorg-video-dummy-0.4.0/src/.libs/dummy_drv.so \
        xserver-xorg-video-dummy-0.4.0/debian/copyright \
        xserver-xorg-video-dummy-0.4.0/COPYING \
        keyboard-install/usr/bin/matchbox-keyboard \
        panel-install/usr/bin/matchbox-panel panel-install/usr/bin/mb-applet-battery
    sudo chown "$(id -u):$(id -g)" "$compiled_cache/compiled.tar.gz"
    (cd "$compiled_cache" && sha256sum compiled.tar.gz >SHA256SUMS)
fi
built="$build/tmp/pb626-build"
sudo install -m 755 "$built"/{pb626-epd,pb626-x11-epd} "$pkg/usr/bin/"
sudo install -D -m 755 "$built/pb626-charge" "$pkg/usr/libexec/pb626-charge"
sudo install -D -m 644 "$built/xserver-xorg-video-dummy-0.4.0/src/.libs/dummy_drv.so" "$pkg/usr/lib/pb626/xorg/drivers/dummy_drv.so"
sudo install -D -m 644 "$built/xserver-xorg-video-dummy-0.4.0/debian/copyright" "$pkg/usr/share/doc/pb626-runtime/xorg-dummy-copyright"
sudo install -D -m 644 "$built/xserver-xorg-video-dummy-0.4.0/COPYING" "$pkg/usr/share/doc/pb626-runtime/xorg-dummy-COPYING"
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
sudo install -D -m 755 diagnostics/pb626-diagnostics "$pkg/usr/sbin/pb626-diagnostics"
sudo install -m 644 diagnostics/pb626-diag-clock.c "$build/tmp/pb626-diag-clock.c"
in_build cc -O2 -Wall -Wextra -Werror /tmp/pb626-diag-clock.c -o /tmp/pb626-diag-clock
in_build /tmp/pb626-diag-clock resolution
sudo install -D -m 755 "$build/tmp/pb626-diag-clock" "$pkg/usr/sbin/pb626-diag-clock"
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
Depends: libc6, bash, evtest, iputils-ping, systemd, dbus, opendoas, util-linux, xinit, xauth, x11-xserver-utils, xserver-xorg-core, xserver-xorg-video-dummy, xserver-xorg-input-evdev, matchbox-window-manager, matchbox-desktop, matchbox-keyboard, matchbox-panel, matchbox-common, libmatchbox1, libx11-6, libxext6, libxtst6, libxdamage1, libxfixes3, libxrandr2, tk, python3-tk, python3-pil.imagetk, mupdf, xterm, htop, mc, nedit, x11-apps, iwd, iwgtk, rfkill, xidle
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
ctl set-default pb626-boot.target
ctl enable pb626-board.service pb626-desktop.service pb626-usb.service pb626-battery.timer pb626-poweroff-screen.service pb626-reboot-marker.service \
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
  for exe in /usr/bin/pb626-epd /usr/bin/pb626-x11-epd /usr/libexec/pb626/bin/* /usr/lib/pb626/xorg/drivers/dummy_drv.so; do
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
  /usr/libexec/pb626-charge --self-test
  # Validate the installed target units/drop-ins with the target Debian
  # systemd version instead of the host version. No services are started.
  systemd-analyze --man=no --generators=no --recursive-errors=one verify \
    pb626-boot.target pb626-boot-select.service pb626-charge.target pb626-charge.service pb626-charge-fallback.service pb626-reboot-marker.service \
    pb626.slice pb626-desktop.service pb626-board.service pb626-usb.service \
    pb626-battery.service pb626-battery.timer pb626-battery-confirm.timer \
    pb626-battery-warning.service pb626-poweroff-screen.service pb626-sleep.service \
    systemd-suspend.service systemd-journald.service systemd-resolved.service systemd-timesyncd.service \
    serial-getty@ttyGS0.service
  udevadm verify /usr/lib/udev/rules.d/7*-pb626-*.rules
'
test "$(ctl get-default)" = pb626-boot.target
for unit in pb626-board.service pb626-desktop.service pb626-usb.service systemd-resolved.service pb626-reboot-marker.service; do
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
