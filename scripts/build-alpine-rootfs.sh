#!/usr/bin/env bash
# Build the cached distribution-owned portion of Alpine.
# Neither kernel modules nor project scripts belong in this cache.
set -Eeuo pipefail
out=alpine-cache/alpine-rootfs.tar.gz
if (( $# >= 1 )); then out=$1; fi
mkdir -p "$(dirname "$out")" rootfs

base=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/armv7
name=alpine-minirootfs-3.24.4-armv7.tar.gz
curl -fsSL --retry 3 "$base/$name" -o "$name"
curl -fsSL --retry 3 "$base/$name.sha256" -o "$name.sha256"
sha256sum -c "$name.sha256"

sudo tar --numeric-owner -xzf "$name" -C rootfs
sudo install -d rootfs/usr/bin rootfs/dev rootfs/proc rootfs/sys \
  rootfs/run rootfs/root rootfs/media/pb626-config
test -e rootfs/dev/null || sudo mknod -m 666 rootfs/dev/null c 1 3
sudo cp /usr/bin/qemu-arm-static rootfs/usr/bin/qemu-arm-static
sudo cp /etc/resolv.conf rootfs/etc/resolv.conf

sudo chroot rootfs /usr/bin/qemu-arm-static /sbin/apk add --no-cache \
  kmod iw wpa_supplicant linux-firmware-rtlwifi \
  openssh-server openssh-keygen e2fsprogs usbutils i2c-tools \
  lm-sensors iproute2 tcpdump aircrack-ng v4l-utils

sudo rm -f rootfs/usr/bin/qemu-arm-static
printf 'nameserver 1.1.1.1\n' | sudo tee rootfs/etc/resolv.conf >/dev/null
sudo chmod 1777 rootfs/tmp
sudo tar --numeric-owner -C rootfs -czf "$out" .
sudo chown "$USER:$USER" "$out"
gzip -t "$out"
echo "Cached Alpine base rootfs: $(stat -c %s "$out") bytes"
