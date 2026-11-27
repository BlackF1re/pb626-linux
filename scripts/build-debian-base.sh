#!/usr/bin/env bash
# Independent signed Debian runtime and compiler chroot cache, no project code.
set -Eeuo pipefail
out=$(realpath -m "${1:?output cache directory}")
test ! -e "$out"
work=$(mktemp -d)
chmod 755 "$work"
trap 'sudo rm -rf "$work"' EXIT
root="$work/root"
build="$work/build"
keys="$work/keys"
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
  lm-sensors v4l-utils curl openssh-server nano htop mc xidle evtest iputils-ping
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
# Source packages are enabled only in the disposable build chroot.
# Obtain the matching Debian Xorg Dummy 0.4.0 source through authenticated APT.
sudo tee "$build/etc/apt/sources.list.d/pb626-build.sources" >/dev/null <<'DDXSOURCE'
Types: deb-src
URIs: https://deb.debian.org/debian
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
DDXSOURCE
in_build apt-get update
in_build env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential autoconf automake libtool pkg-config gettext autopoint intltool \
  libx11-dev libxext-dev libxft-dev libxrender-dev libxcursor-dev libxfixes-dev \
  libxtst-dev libxdamage-dev libxrandr-dev libpng-dev libjpeg-dev libexpat1-dev libfakekey-dev \
  libmatchbox-dev libstartup-notification0-dev libcairo2-dev \
  xserver-xorg-dev xutils-dev libpciaccess-dev

# Save numeric owners, hardlinks, ACLs and xattrs in a host-owned archive.
# No project code, kernel, credentials or machine identity enters the cache.
for d in "$root" "$build"; do
    sudo rm -f "$d/etc/resolv.conf"
    sudo truncate -s 0 "$d/etc/machine-id"
    sudo rm -f "$d"/etc/ssh/ssh_host_*
    sudo rm -f "$d/var/lib/dbus/machine-id"
    sudo chroot "$d" apt-get clean
done
mkdir -p "$out"
sudo tar --numeric-owner --acls --xattrs -C "$work" -czf "$out/debian-chroots.tar.gz" root build
sudo chown "$(id -u):$(id -g)" "$out/debian-chroots.tar.gz"
(cd "$out" && sha256sum debian-chroots.tar.gz >SHA256SUMS)
