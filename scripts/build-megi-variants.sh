#!/usr/bin/env bash
# Build standard RAM DTBs and ELAN diagnostic DTBs.
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
for variant in elan-display elan-emmc-backup elan-emmc-native; do
  cp "$original" "$src"
  cat "$repo/board/megi/common-sd.fragment" >> "$src"
  case "$variant" in
    elan-display|elan-emmc-native)
      for fragment in elan elan-display elan-ektf2227; do
        cat "$repo/board/megi/$fragment.fragment" >> "$src"
      done
      if [[ $variant == elan-emmc-native ]]; then cat "$repo/board/megi/elan-emmc-native.fragment" >> "$src"; fi
      ;;
    elan-emmc-backup)
      for fragment in elan elan-usbtest elan-emmc-backup; do
        cat "$repo/board/megi/$fragment.fragment" >> "$src"
      done
      ;;
    *)
      cat "$repo/board/megi/$variant.fragment" >> "$src"
      ;;
  esac
  # Built-in driver must not probe non-display RAM or recovery variants.
  if [[ "$variant" == elan-display || "$variant" == elan-emmc-native ]]; then
    printf '\n&{/soc/display-controller@1c0c000} { status = "okay"; };\n' >> "$src"
  else
    printf '\n&{/soc/display-controller@1c0c000} { status = "disabled"; };\n' >> "$src"
  fi
  make -C "$linux" -j2 "$target"
  cp "$linux/arch/arm/boot/dts/$target" "$out/pb626-$variant.dtb"
done
for dtb in "$out"/pb626-*.dtb; do
  test "$(fdtget -t s "$dtb" '/memory@40000000' device_type)" = memory
  test "$(fdtget -t x "$dtb" '/memory@40000000' reg)" = "40000000 10000000"
  emmc_status=disabled
  case "${dtb##*/}" in
    pb626-elan-emmc-backup.dtb)
      emmc_status=okay
      sd_status=disabled
      fdtget "$dtb" /chosen pb626,emmc-backup >/dev/null
      ;;
    pb626-elan-display.dtb) sd_status=disabled ;;
    pb626-elan-emmc-native.dtb) emmc_status=okay; sd_status=disabled; fdtget "$dtb" /chosen pb626,emmc-root >/dev/null ;;
    *) sd_status=okay ;;
  esac
  test "$(fdtget -t s "$dtb" '/soc/mmc@1c11000' status)" = "$emmc_status"
  test "$(fdtget -t s "$dtb" '/soc/mmc@1c0f000' status)" = "$sd_status"
  test "$(fdtget -t s "$dtb" '/soc/display-controller@1c0c000' compatible)" = 'custom,pocketbook-touch-lux-3-tcon0-ed060xd4-display'
  display_status=disabled
  case "${dtb##*/}" in pb626-elan-display.dtb|pb626-elan-emmc-native.dtb) display_status=okay;; esac
  test "$(fdtget -t s "$dtb" /soc/display-controller@1c0c000 status)" = "$display_status"
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
phy=/soc/phy@1c13400
display="$out/pb626-elan-display.dtb"
test "$(fdtget -t s "$display" '/soc/i2c@1c2b400/touchscreen@15' compatible)" = 'elan,ektf2227'
if fdtget -t x "$display" "$phy" usb0_vbus_det-gpios >/dev/null 2>&1; then
  echo 'elan-display must use the USB peripheral VBUS fallback' >&2
  exit 1
fi
test "$(fdtget -t s "$display" /soc/pwm@1c20e00 status)" = okay
read -r pwm channel period flags <<< "$(fdtget -t x "$display" /backlight pwms)"
test "$pwm" = "$(fdtget -t x "$display" /soc/pwm@1c20e00 phandle)"
test "$channel $period $flags" = '0 186a0 0'
test "$(fdtget -t s "$display" /backlight pinctrl-names)" = 'default pwm-on'
off_pins=/soc/pinctrl@1c20800/pb626-backlight-off-pins
test "$(fdtget -t x "$display" /backlight pinctrl-0)" = "$(fdtget -t x "$display" "$off_pins" phandle)"
test "$(fdtget -t s "$display" "$off_pins" pins)" = PB2
test "$(fdtget -t s "$display" "$off_pins" function)" = gpio_in
test "$(fdtget -t x "$display" /backlight pinctrl-1)" = "$(fdtget -t x "$display" /soc/pinctrl@1c20800/pwm0-pin phandle)"
test "$(fdtget -t u "$display" /backlight post-pwm-on-delay-ms)" = 1
test "$(fdtget -t u "$display" /backlight pwm-off-delay-ms)" = 1
read -r gpio bank pin flags <<< "$(fdtget -t x "$display" /backlight enable-gpios)"
test "$gpio" = "$(fdtget -t x "$display" /soc/pinctrl@1c20800 phandle)"
test "$bank $pin $flags" = '1 4 0'
test "$(fdtget -t i "$display" /soc/display-controller@1c0c000 vcom-microvolt)" = 2440000
fdtget -t x "$display" /chosen pb626,display-bringup >/dev/null
