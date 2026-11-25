#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
rev=c40c8f325f3095e9846920dbb08b02726fbebe81
for cmd in git python3 curl qemu-arm-static chroot; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }; done
[[ $(id -u) = 0 ]]
if ! git cat-file -e "$rev^{commit}" 2>/dev/null; then git fetch origin "$rev"; fi
[[ $(git rev-parse "$rev^{commit}") = "$rev" ]]
work=$(mktemp -d /tmp/pb626-preclear.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/src" "$work/root"
python3 "$here/prepare.py" "$work/src"
sh -n "$work/src/xsession.experimental"
name=alpine-minirootfs-3.24.4-armv7.tar.gz
base=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/armv7
(cd "$work"; curl -fsSL --retry 3 "$base/$name" -o "$name"; curl -fsSL --retry 3 "$base/$name.sha256" -o "$name.sha256"; sha256sum -c "$name.sha256")
r="$work/root"
tar --numeric-owner -xzf "$work/$name" -C "$r"
install -d "$r/usr/bin" "$r/dev" "$r/tmp"
[[ -e "$r/dev/null" ]] || mknod -m 666 "$r/dev/null" c 1 3
[[ -e "$r/dev/urandom" ]] || mknod -m 666 "$r/dev/urandom" c 1 9
cp "$(command -v qemu-arm-static)" "$r/usr/bin/qemu-arm-static"
cp -L /etc/resolv.conf "$r/etc/resolv.conf"
cp "$work/src/"*.c "$work/src/"*.h "$r/tmp/"
cp -r "$here/uapi" "$r/tmp/uapi"
inroot() { chroot "$r" /usr/bin/qemu-arm-static "$@"; }
inroot /sbin/apk add --no-cache build-base linux-headers libx11-dev libxext-dev libxtst-dev libxdamage-dev libxfixes-dev
inroot /bin/sh -ec 'cd /tmp; cc -O3 -Wall -Wextra -Werror -I uapi pb626-epd.c -o pb626-epd-preclear-v2; cc -O2 -Wall -Wextra -Werror -I uapi test-pb626-epd.c -o test-pb626-epd; ./test-pb626-epd; test "$(./pb626-epd-preclear-v2 --protocol)" = pb626-epd-shm-4-preclear; cc -O2 -Wall -Wextra -Werror pb626-x11-epd.c -o pb626-x11-epd-preclear-v2 -lX11 -lXext -lXtst -lXdamage -lXfixes -lm; cc -O2 -Wall -Wextra -Werror test-pb626-x11-epd.c -o test-pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lm; ./test-pb626-x11-epd; strip pb626-epd-preclear-v2 pb626-x11-epd-preclear-v2'
mkdir -p "$here/out"
cp "$r/tmp/pb626-x11-epd-preclear-v2" "$r/tmp/pb626-epd-preclear-v2" "$here/out/"
cp "$work/src/"xsession.* "$here/out/"
cp "$work/src/pb626-x11-epd.c" "$work/src/pb626-epd.c" "$work/src/pb626-epd.h" "$here/out/"
(cd "$here/out"; sha256sum pb626-x11-epd-preclear-v2 pb626-epd-preclear-v2 xsession.original xsession.experimental xsession.v1 pb626-x11-epd.c pb626-epd.c pb626-epd.h > SHA256SUMS; cat SHA256SUMS)
echo PRECLEAR_V2_BUILD_READY
