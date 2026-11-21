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

# Build hcxdumptool 7.1.2 as native Alpine/musl ARMv7 on the CI runner
# under QEMU; do NOT install the large compiler toolchain onto the reader.
# Pin upstream commit and verify exactly what source we compile.
hcx_revision=10aa88d3e955f507f56d24d3779ac251c4004c1c
git clone --quiet https://github.com/ZerBea/hcxdumptool.git hcx-source
test "$(git -C hcx-source rev-parse "$hcx_revision^{commit}")" = "$hcx_revision"
git -C hcx-source checkout --quiet --detach "$hcx_revision"
sudo install -d rootfs/tmp/hcxdumptool
sudo cp -a hcx-source/. rootfs/tmp/hcxdumptool/
sudo chroot rootfs /usr/bin/qemu-arm-static /sbin/apk add --no-cache libpcap
sudo chroot rootfs /usr/bin/qemu-arm-static /sbin/apk add --no-cache \
  --virtual .pb626-hcx-build build-base linux-headers libpcap-dev openssl-dev
sudo chroot rootfs /usr/bin/qemu-arm-static /usr/bin/make -C /tmp/hcxdumptool -j1
sudo chroot rootfs /usr/bin/qemu-arm-static /usr/bin/make -C /tmp/hcxdumptool install
sudo chroot rootfs /usr/bin/qemu-arm-static /usr/bin/hcxdumptool -v
test -s rootfs/usr/bin/hcxdumptool
sudo chroot rootfs /usr/bin/qemu-arm-static /sbin/apk del .pb626-hcx-build
sudo rm -rf rootfs/tmp/hcxdumptool hcx-source

sudo rm -f rootfs/usr/bin/qemu-arm-static
printf 'nameserver 1.1.1.1\n' | sudo tee rootfs/etc/resolv.conf >/dev/null
sudo chmod 1777 rootfs/tmp
sudo tar --numeric-owner -C rootfs -czf "$out" .
sudo chown "$USER:$USER" "$out"
gzip -t "$out"
echo "Cached Alpine base rootfs: $(stat -c %s "$out") bytes"
