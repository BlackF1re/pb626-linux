#!/usr/bin/env bash
# Build four FEL-only DTBs from Megi's original complete device tree.
set -euo pipefail
if (( $# != 3 )); then
  echo 'usage: build-megi-variants.sh LINUX_TREE OUT_DIR REPOSITORY_ROOT' >&2
  exit 2
fi
linux=$(realpath "$1")
out=$(realpath -m "$2")
repo=$(realpath "$3")
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
src="$linux/arch/arm/boot/dts/sun5i-a13-pocketbook-touch-lux-3.dts"
original=$(mktemp)
cp "$src" "$original"
trap 'cp "$original" "$src"; rm -f "$original"' EXIT
mkdir -p "$out"
for variant in cypress elan focaltech no-touch; do
  cp "$original" "$src"
  cat "$repo/board/megi/common-sd.fragment" >> "$src"
  if [[ $variant != cypress ]]; then
    cat "$repo/board/megi/$variant.fragment" >> "$src"
  fi
  make -C "$linux" -j2 dtbs
  cp "$linux/arch/arm/boot/dts/sun5i-a13-pocketbook-touch-lux-3.dtb" "$out/pb626-$variant.dtb"
done
for dtb in "$out"/pb626-*.dtb; do
  test "$(fdtget -t s "$dtb" '/soc/mmc@1c11000' status)" = disabled
  test "$(fdtget -t s "$dtb" '/soc/mmc@1c0f000' status)" = okay
  test "$(fdtget -t s "$dtb" '/soc/display-controller@1c0c000' compatible)" = 'custom,pocketbook-touch-lux-3-tcon0-ed060xd4-display'
done
test "$(fdtget -t s "$out/pb626-elan.dtb" '/soc/i2c@1c2b400/touchscreen@15' compatible)" = 'elan,ekth3500'
