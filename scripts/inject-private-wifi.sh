#!/usr/bin/env bash
# Produce a PRIVATE local RAM image, never a GitHub artifact. Uses no eMMC.
# The WPA PSK file is password-equivalent: never push/share the result.
set -Eeuo pipefail
if (( $# != 3 )); then
  echo 'usage: inject-private-wifi.sh INPUT_BUNDLE NEW_OUTPUT_DIR LOCAL_WPA_CONF' >&2
  exit 2
fi
src=$(realpath -- "$1")
dst=$(realpath -m -- "$2")
conf=$(realpath -- "$3")
[[ -d $src && -s $src/SHA256SUMS && -s $src/pb626-megi-initramfs.cpio.gz && -s $conf ]] || exit 2
[[ ! -e $dst && $src != "$dst" ]] || { echo 'Output must be a new directory' >&2; exit 2; }
for t in cpio fdtget fdtput sha256sum gzip stat; do
  command -v "$t" >/dev/null || { echo "Missing $t" >&2; exit 2; }
done
(cd "$src" && sha256sum -c SHA256SUMS >/dev/null)
grep -qF 'network={' "$conf" || { echo 'Missing WPA network block' >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
umask 077
mkdir -m 700 -- "$dst"
cp -a -- "$src"/. "$dst"/
(gzip -cd -- "$src/pb626-megi-initramfs.cpio.gz" |
  (cd "$work" && cpio -id --quiet --no-absolute-filenames))
install -d -m 700 -- "$work/etc/pb626"
install -m 600 -- "$conf" "$work/etc/pb626/wpa_supplicant.conf"
(cd "$work" && find . -print0 | cpio --null -o --format=newc --quiet) |
  gzip -9 -n > "$dst/pb626-megi-initramfs.cpio.gz"
size=$(stat -c '%s' "$dst/pb626-megi-initramfs.cpio.gz")
(( size < 0x50000000 - 0x45000000 )) || { echo 'Initramfs too large' >&2; exit 4; }
printf -v initrd_end '%x' "$((0x45000000 + size))"
for d in "$dst"/pb626-*.dtb; do
  [[ $(fdtget -t s "$d" '/soc/mmc@1c11000' status) == disabled ]] || exit 4
  [[ $(fdtget -t x "$d" /chosen linux,initrd-start) == 45000000 ]] || exit 4
  fdtput -t x "$d" /chosen linux,initrd-end "$initrd_end"
  [[ $(fdtget -t x "$d" /chosen linux,initrd-end) == "$initrd_end" ]] || exit 4
done
(cd "$dst" && sha256sum pb626-megi-zImage *.dtb *.gz *.config > SHA256SUMS &&
 sha256sum -c SHA256SUMS >/dev/null)
echo 'PRIVATE RAM WIFI BUNDLE READY (contains WLAN credential; never upload/share)'
