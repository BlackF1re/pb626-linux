#!/usr/bin/env bash
# Source preparation and expensive kernel compilation; CI keys these bytes
# rather than unrelated workflow YAML, upload configuration or packaging.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
case "${1:-}" in
prepare)
set -euo pipefail
pin=facc87117511221bb61410e3f92ad8579697f736
git init -q linux
if ! git -C linux cat-file -e "$pin^{commit}" 2>/dev/null; then
  git -C linux fetch -q --depth 1 https://github.com/Arnavion/linux.git "$pin"
  test "$(git -C linux rev-parse FETCH_HEAD)" = "$pin"
fi
git -C linux checkout -q --force --detach "$pin"
test "$(git -C linux rev-parse HEAD)" = facc87117511221bb61410e3f92ad8579697f736
grep -q '^VERSION = 7$' linux/Makefile
grep -q '^PATCHLEVEL = 2$' linux/Makefile
f=linux/drivers/clocksource/timer-sun4i.c
grep -q 'sun4i_clkevt_wait_reload' "$f"
grep -q 'TIMER_SYNC_TICKS + 1' "$f"
test -f linux/drivers/video/fbdev/sun5i-eink.c
test -f linux/drivers/regulator/tps65185.c
test -f linux/arch/arm/configs/pocketbook_touch_lux_3_defconfig
test -f linux/arch/arm/boot/dts/allwinner/sun5i-a13-pocketbook-touch-lux-3.dts
git -C linux apply "$repo/patches/pwm-backlight-disconnect-when-off.patch"
git -C linux apply "$repo/patches/ektf2227-pocketbook-touch.patch"
git -C linux apply --check "$repo/patches/a13-mbus-dma-devlink.patch"
git -C linux apply "$repo/patches/a13-mbus-dma-devlink.patch"
git -C linux apply --check "$repo/patches/sun5i-eink-runtime-pm.patch"
git -C linux apply "$repo/patches/sun5i-eink-runtime-pm.patch"
git -C linux apply --check "$repo/patches/sun4i-lradc-system-pm.patch"
git -C linux apply "$repo/patches/sun4i-lradc-system-pm.patch"
git -C linux apply --check "$repo/patches/axp209-boot-source.patch"
git -C linux apply "$repo/patches/axp209-boot-source.patch"
for patch in sun5i-pm-twi-read sun5i-pm-sram-abort sun5i-pm-prepare-rollback sun5i-pm-watchdog; do
  git -C linux apply --check "$repo/patches/suspend/$patch.patch"
  git -C linux apply "$repo/patches/suspend/$patch.patch"
done
git -C linux diff --check
;;
compile)
set -euo pipefail
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
# A stale cache must never be mixed with newly generated DTBs.
if [ "${2:-false}" = true ]; then
  rm -rf kernel-cache
fi
bash scripts/configure-megi-kernel.sh
make -C linux -j"$(nproc)" KCFLAGS=-Wno-error zImage modules
mkdir -p kernel-cache module-root
cp linux/arch/arm/boot/zImage kernel-cache/pb626-megi-zImage
cp linux/.config kernel-cache/pb626-megi.config
test -s linux/arch/arm/mach-sunxi/pm-sun5i.o
cp linux/arch/arm/mach-sunxi/sleep-sun5i.o kernel-cache/
arm-linux-gnueabihf-objdump -dr kernel-cache/sleep-sun5i.o > kernel-cache/sram-disassembly.txt
release=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' linux/include/generated/utsrelease.h)
test -n "$release"
printf '%s\n' "$release" > kernel-cache/KERNELRELEASE
make -C linux modules_install KERNELRELEASE="$release" INSTALL_MOD_PATH="$PWD/module-root" INSTALL_MOD_STRIP=1 DEPMOD=true
depmod -b module-root "$release"
tar -C module-root -czf kernel-cache/kernel-modules.tar.gz lib/modules
printf '%s\n' 'Tag: orange-pi-7.2-20260903-2131' \
  'Git commit: facc87117511221bb61410e3f92ad8579697f736' \
  'Maintainer: Ondrej Jirman (megi); mirror: Arnavion/linux' > kernel-cache/KERNEL-SOURCE.txt
echo 'Local patch: patches/pwm-backlight-disconnect-when-off.patch' >> kernel-cache/KERNEL-SOURCE.txt
echo 'Local patch: patches/ektf2227-pocketbook-touch.patch' >> kernel-cache/KERNEL-SOURCE.txt
echo 'Local patch: patches/a13-mbus-dma-devlink.patch' >> kernel-cache/KERNEL-SOURCE.txt
echo 'Local patch: patches/sun5i-eink-runtime-pm.patch' >> kernel-cache/KERNEL-SOURCE.txt
echo 'Local patch: patches/sun4i-lradc-system-pm.patch' >> kernel-cache/KERNEL-SOURCE.txt
echo 'Local patch: patches/axp209-boot-source.patch' >> kernel-cache/KERNEL-SOURCE.txt
for patch in sun5i-pm-twi-read sun5i-pm-sram-abort sun5i-pm-prepare-rollback sun5i-pm-watchdog; do
  echo "Local patch: patches/suspend/$patch.patch" >> kernel-cache/KERNEL-SOURCE.txt
done
;;
*) echo 'Usage: build-megi-kernel.sh prepare|compile [rebuild]' >&2; exit 2;;
esac
