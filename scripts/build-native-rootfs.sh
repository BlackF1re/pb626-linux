#!/usr/bin/env bash
# Native-only system packages and configuration. Do not add these to FEL RAM.
set -Eeuo pipefail
root=$(realpath "${1:?native staging root}")
test -d "$root/etc"
test -x "$root/usr/bin/pb626-epd"
test -s "$root/etc/pb626-image-id"
host_apk=$(mktemp -d)
trap 'sudo rm -f "$root/usr/bin/qemu-arm-static"; sudo rm -rf "$host_apk"' EXIT
sudo install -m 755 /usr/bin/qemu-arm-static "$root/usr/bin/"
in_root() { sudo chroot "$root" /usr/bin/qemu-arm-static "$@"; }

# QEMU user-mode can fail apk's permission-preservation operation for
# setuid/setgid files (bbsuid, doas, D-Bus launch helper, wall).
# Use a host-native apk of the same Alpine release to extract ARM packages.
# Package scripts still execute in the target chroot via ARM binfmt.
# Do not ignore apk errors or reconstruct package permissions by hand.
test "$(uname -m)" = x86_64
host_base=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64
host_archive=alpine-minirootfs-3.24.4-x86_64.tar.gz
(
    cd "$host_apk"
    curl -fsSL --retry 3 "$host_base/$host_archive" -o "$host_archive"
    curl -fsSL --retry 3 "$host_base/$host_archive.sha256" -o "$host_archive.sha256"
    sha256sum -c "$host_archive.sha256"
    mkdir host
    sudo tar --numeric-owner -xzf "$host_archive" -C host
)
host="$host_apk/host"
native_apk() {
    sudo "$host/lib/ld-musl-x86_64.so.1" \
        --library-path "$host/lib:$host/usr/lib" "$host/sbin/apk" \
        --root "$root" --arch armv7 "$@"
}
# Check the actual execution path used by package post-install scripts.
sudo chroot "$root" /bin/true
native_apk --version
sudo cp /etc/resolv.conf "$root/etc/resolv.conf"
# Community is needed for ConnMan and zram-init; stay on the same Alpine branch.
printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main' \
  'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' | sudo tee "$root/etc/apk/repositories" >/dev/null
native_apk add --no-cache alpine-base ifupdown-ng ifupdown-ng-openrc \
  connman connman-openrc dbus dbus-openrc zram-init zram-init-openrc \
  doas tk tzdata ca-certificates nano curl openssh-sftp-server \
  openssh-server-common-openrc wpa_supplicant-openrc mupdf-x11
# Check package-owned privilege metadata on the host, not under QEMU.
# A rootfs with missing set-ID bits may boot but cannot authenticate users
# or start privileged D-Bus services correctly.
test "$(sudo stat -c '%a:%u:%g' "$root/bin/bbsuid")" = 4111:0:0
test "$(sudo stat -c '%a:%u:%g' "$root/usr/bin/doas")" = 4755:0:0
dbus_gid=$(sudo awk -F: '$1 == "messagebus" {print $3}' "$root/etc/group")
test -n "$dbus_gid"
test "$(sudo stat -c '%a:%u:%g' "$root/usr/libexec/dbus-daemon-launch-helper")" = "4750:0:$dbus_gid"
sudo test -g "$root/usr/bin/wall"
echo 'Native APK privilege metadata verified'
# No network daemon, GUI toolkit or PDF viewer is launched during assembly.
sudo install -d -m 755 "$root/usr/libexec" "$root/etc/pb626" "$root/etc/modprobe.d" \
  "$root/etc/network" "$root/etc/ssh" "$root/var/log" "$root/var/lib/xkb"
sudo chmod 755 "$root/etc/pb626"
sudo install -d -m 700 "$root/var/lib/pb626"
sudo install -m 755 boot/pb626-native-{desktop,console} "$root/sbin/"
sudo install -m 644 boot/pb626-native.inittab "$root/etc/inittab"
sudo install -m 755 boot/native/init.d/* "$root/etc/init.d/"
sudo install -m 755 boot/native/pb626-{usb,user-session} "$root/usr/libexec/"
sudo install -m 755 boot/native/pb626-admin "$root/usr/sbin/"
sudo install -m 600 boot/native/doas.conf "$root/etc/doas.conf"
sudo install -m 644 boot/native/fstab "$root/etc/fstab"
sudo install -m 644 boot/native/zram-init "$root/etc/conf.d/zram-init"
sudo install -m 644 boot/native/syslog "$root/etc/conf.d/syslog"
sudo install -m 600 boot/native/sshd_config "$root/etc/ssh/sshd_config"
sudo install -m 755 display/pb626-control-center "$root/usr/bin/"
sudo install -m 755 display/pb626-open-document "$root/usr/bin/"
sudo install -m 644 tests/check-control-center.tcl "$root/usr/libexec/pb626-check-tk.tcl"
sudo install -m 644 display/native/*.desktop "$root/usr/share/applications/"
# Native desktop settings are now provided by the control center.
sudo rm -f "$root/usr/share/applications/pb626-frontlight.desktop" "$root/usr/share/applications/pb626-status.desktop"
# Stable base config. ConnMan owns non-loopback links and DNS.
printf 'pb626\n' | sudo tee "$root/etc/hostname" >/dev/null
printf '127.0.0.1 localhost pb626\n::1 localhost\n' | sudo tee "$root/etc/hosts" >/dev/null
printf 'auto lo\niface lo inet loopback\n' | sudo tee "$root/etc/network/interfaces" >/dev/null
printf 'blacklist lima\n' | sudo tee "$root/etc/modprobe.d/pb626.conf" >/dev/null
printf 'rtl8xxxu\n' | sudo tee "$root/etc/modules" >/dev/null
printf '\n# PB626: independent USB and desktop startup\nrc_parallel="YES"\n' | sudo tee -a "$root/etc/rc.conf" >/dev/null
printf '\nvm.swappiness=100\n' | sudo tee -a "$root/etc/sysctl.conf" >/dev/null
sudo ln -snf /usr/share/zoneinfo/UTC "$root/etc/localtime"
printf 'UTC\n' | sudo tee "$root/etc/timezone" >/dev/null
# User applications never get board-device or disk group access.
in_root /bin/sh -ec 'addgroup -g 1000 reader; adduser -D -u 1000 -G reader -s /bin/sh reader; passwd -l reader || :; passwd -l root || :'
sudo install -d -m 755 -o 1000 -g 1000 "$root/home/reader/Books" "$root/home/reader/Documents" "$root/home/reader/Downloads"
# Root can log in only with the password provisioned by the offline installer.
if ! sudo grep -qx ttyGS0 "$root/etc/securetty" 2>/dev/null; then
  printf 'ttyGS0\n' | sudo tee -a "$root/etc/securetty" >/dev/null
fi
# Do not start services in a build chroot. rc-update only installs links.
enable() {
  local level=$1; shift
  for svc in "$@"; do
    test -x "$root/etc/init.d/$svc"
    in_root /sbin/rc-update add "$svc" "$level"
  done
}
enable sysinit devfs dmesg mdev hwdrivers
enable boot modules hwclock fsck root localmount hostname sysctl bootmisc syslog klogd networking zram-init
enable default pb626-board pb626-desktop pb626-usb pb626-console
enable shutdown killprocs mount-ro
# ConnMan is enabled from settings on demand and remembers paired networks.
# SSH and acpid are explicitly opt-in; suspend/charger mode are not qualified.
for svc in connman sshd wpa_supplicant acpid; do
  for level in sysinit boot default; do
    if [ -L "$root/etc/runlevels/$level/$svc" ]; then in_root /sbin/rc-update del "$svc" "$level"; fi
  done
done
# Never carry host DNS, credentials, SSH keys or machine identity into artifacts.
sudo rm -f "$root/etc/ssh"/ssh_host_* "$root/etc/machine-id" "$root/var/lib/dbus/machine-id"
sudo rm -f "$root/etc/resolv.conf"
printf '# Managed by the network manager\n' | sudo tee "$root/etc/resolv.conf" >/dev/null
sudo rm -f "$root/init" "$root/usr/sbin/pb626-network"
# Build-time contract checks against the real assembled ARM root.
in_root /bin/sh -ec '
  command -v rc-service; command -v supervise-daemon; command -v connmanctl
  command -v wish; command -v doas; command -v getty
  command -v mupdf-x11 || command -v mupdf
  test -x /usr/bin/connmanctl
  test -x /usr/bin/xrdb
  test -L /etc/runlevels/sysinit/devfs
  test -L /etc/runlevels/boot/fsck
  test -L /etc/runlevels/boot/zram-init
  test -L /etc/runlevels/default/pb626-desktop
  test -L /etc/runlevels/shutdown/mount-ro
  test ! -e /etc/runlevels/default/sshd
  test ! -e /etc/runlevels/default/connman
  test "$(id -u reader)" = 1000
  test "$(id -g reader)" = 1000
  awk -F: '\''($1=="root" || $1=="reader") && $2 ~ /^[!*]/ {n++} END {exit n!=2}'\'' /etc/shadow
  test "$(su -s /bin/sh -c "id -u" reader)" = 1000
  /lib/ld-musl-armhf.so.1 --list /usr/bin/pb626-x11-epd
  /lib/ld-musl-armhf.so.1 --list /usr/bin/matchbox-window-manager
  test "$(/usr/bin/pb626-epd --protocol)" = pb626-epd-shm-4
  tclsh /usr/libexec/pb626-check-tk.tcl /usr/bin/pb626-control-center /usr/bin/pb626-open-document
'
sudo rm -f "$root/usr/libexec/pb626-check-tk.tcl"
in_root /sbin/apk info -v | LC_ALL=C sort
echo "Native rootfs size: $(sudo du -sm "$root" | cut -f1) MiB (on eMMC)"
