#!/usr/bin/env bash
# Build four RAM-only DTBs from the pinned Megi 7.2 mainline device tree.
set -euo pipefail
if (( $# != 3 )); then
  echo 'usage: build-megi-variants.sh LINUX_TREE OUT_DIR REPOSITORY_ROOT' >&2
  exit 2
fi
linux=$(realpath "$1")
out=$(realpath -m "$2")
repo=$(realpath "$3")
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
# Megi Linux >=6.5 moves the board DTS under the allwinner directory.
src="$linux/arch/arm/boot/dts/allwinner/sun5i-a13-pocketbook-touch-lux-3.dts"
test -f "$src"
target=allwinner/sun5i-a13-pocketbook-touch-lux-3.dtb
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
  make -C "$linux" -j2 "$target"
  cp "$linux/arch/arm/boot/dts/$target" "$out/pb626-$variant.dtb"
done
for dtb in "$out"/pb626-*.dtb; do
  test "$(fdtget -t s "$dtb" '/memory@40000000' device_type)" = memory
  test "$(fdtget -t x "$dtb" '/memory@40000000' reg)" = "40000000 10000000"
  test "$(fdtget -t s "$dtb" '/soc/mmc@1c11000' status)" = disabled
  test "$(fdtget -t s "$dtb" '/soc/mmc@1c0f000' status)" = okay
  test "$(fdtget -t s "$dtb" '/soc/display-controller@1c0c000' compatible)" = 'custom,pocketbook-touch-lux-3-tcon0-ed060xd4-display'
  # Essential Megi board devices: firmware pinout does not equal driver success.
  test "$(fdtget -t s "$dtb" '/soc/usb@1c13000' dr_mode)" = peripheral
  test "$(fdtget -t s "$dtb" '/soc/usb@1c13000' status)" = okay
  test "$(fdtget -t s "$dtb" '/soc/usb@1c14000' status)" = okay
  test "$(fdtget -t s "$dtb" '/soc/usb@1c14400' status)" = okay
  test "$(fdtget -t s "$dtb" '/soc/spi@1c17000' status)" = okay
  test "$(fdtget -t s "$dtb" '/soc/spi@1c17000/flash@0' compatible)" = 'macronix,mx25u4033 jedec,spi-nor'
  test "$(fdtget -t s "$dtb" '/soc/i2c@1c2ac00/pmic@34' compatible)" = x-powers,axp209
  test "$(fdtget -t s "$dtb" '/soc/i2c@1c2b000/rtc@51' compatible)" = nxp,pcf8563
  test "$(fdtget -t s "$dtb" '/soc/i2c@1c2b000/pmic@68' compatible)" = ti,tps65185
  test "$(fdtget -t s "$dtb" '/backlight' compatible)" = pwm-backlight
  test "$(fdtget -t x "$dtb" '/backlight' default-brightness-level)" = 0
  fdtget -t x "$dtb" '/backlight' brightness-levels > /dev/null
  test "$(fdtget -t s "$dtb" '/leds' compatible)" = gpio-leds
done
test "$(fdtget -t s "$out/pb626-elan.dtb" '/soc/i2c@1c2b400/touchscreen@15' compatible)" = 'elan,ekth3500'
