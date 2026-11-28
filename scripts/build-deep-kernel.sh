#!/usr/bin/env bash
# Build the isolated deep kernel; never feed ordinary firmware caches.
set -euo pipefail
mkdir -p deep-resume-lab
bash scripts/build-megi-kernel.sh prepare
bash scripts/configure-megi-kernel.sh
cp linux/.config deep-resume-lab/production.config
for patch in patches/lab/sun5i-pm-twi-read.patch patches/lab/sun5i-pm-sram-abort.patch patches/lab/sun5i-pm-prepare-rollback.patch patches/lab/sun5i-pm-watchdog.patch; do
  git -C linux apply --check "$PWD/$patch"
  git -C linux apply "$PWD/$patch"
done
linux/scripts/config --file linux/.config -e SUN5I_PM --set-str LOCALVERSION '-pb626-deep-lab'
make -C linux olddefconfig
grep -qx 'CONFIG_SUN5I_PM=y' linux/.config
grep -qx 'CONFIG_ARM_CPU_SUSPEND=y' linux/.config
cp linux/.config deep-resume-lab/experimental.config
# One Kbuild invocation for the complete kernel and modules.
make -C linux -j"$(nproc)" KCFLAGS=-Wno-error zImage modules
test -s linux/arch/arm/mach-sunxi/pm-sun5i.o
test -s linux/arch/arm/mach-sunxi/sleep-sun5i.o
cp linux/arch/arm/boot/zImage deep-resume-lab/zImage
cp linux/arch/arm/mach-sunxi/sleep-sun5i.o deep-resume-lab/
arm-linux-gnueabihf-objdump -dr linux/arch/arm/mach-sunxi/sleep-sun5i.o > deep-resume-lab/sram-disassembly.txt
arm-linux-gnueabihf-size linux/arch/arm/mach-sunxi/{pm-sun5i,sleep-sun5i}.o > deep-resume-lab/object-sizes.txt
arm-linux-gnueabihf-nm linux/vmlinux | awk '$3 == "cpu_resume" {print $1}' > deep-resume-lab/cpu-resume-virtual.txt
test "$(wc -l < deep-resume-lab/cpu-resume-virtual.txt)" -eq 1
release=$(cat linux/include/config/kernel.release)
test -n "$release"
printf '%s\n' "$release" > deep-resume-lab/KERNELRELEASE
make -C linux modules_install KERNELRELEASE="$release" INSTALL_MOD_PATH="$PWD/deep-module-root" INSTALL_MOD_STRIP=1 DEPMOD=true
depmod -b deep-module-root "$release"
tar -C deep-module-root -czf deep-resume-lab/kernel-modules.tar.gz lib/modules
bash scripts/build-megi-variants.sh linux deep-dtbs "$PWD"
cp deep-dtbs/pb626-elan-emmc-native.dtb deep-resume-lab/
git -C linux diff --check
cp /tmp/deep-toolchain deep-resume-lab/toolchain.txt
(cd deep-resume-lab && sha256sum production.config experimental.config zImage sleep-sun5i.o sram-disassembly.txt object-sizes.txt cpu-resume-virtual.txt KERNELRELEASE kernel-modules.tar.gz pb626-elan-emmc-native.dtb toolchain.txt > SHA256SUMS)
