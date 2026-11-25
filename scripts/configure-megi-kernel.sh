#!/usr/bin/env bash
# Kconfig contract for the pinned Megi 7.2 PocketBook / A13 RAM image.
# Updating this file invalidates the prebuilt kernel cache, not the Alpine cache.
set -Eeuo pipefail
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-

make -C linux pocketbook_touch_lux_3_defconfig
c=linux/scripts/config
"$c" --file linux/.config \
  -e USB -e NOP_USB_XCEIV -e EXTCON -e PHY_SUN4I_USB \
  -e USB_MUSB_HDRC -e USB_MUSB_SUNXI -e USB_MUSB_DUAL_ROLE \
  -e USB_GADGET -e USB_LIBCOMPOSITE -e USB_CONFIGFS \
  -e USB_CONFIGFS_ACM -e USB_CONFIGFS_MASS_STORAGE \
  -e USB_EHCI_HCD -e USB_EHCI_HCD_PLATFORM \
  -e USB_OHCI_HCD -e USB_OHCI_HCD_PLATFORM \
  -e MMC -e MMC_BLOCK -e MMC_SUNXI -e EXT4_FS -e VFAT_FS \
  -e ARM_APPENDED_DTB -e AUTO_ZRELADDR -d ARM_ATAG_DTB_COMPAT \
  -e BLK_DEV_INITRD -e RD_GZIP \
  -e DEVTMPFS -e DEVTMPFS_MOUNT -e CONFIGFS_FS \
  -d REGULATOR_TP65185X -e REGULATOR_TPS65185 -e BACKLIGHT_PWM \
  -e MEDIA_SUPPORT -e MEDIA_PLATFORM_SUPPORT -e VIDEO_DEV \
  -e TOUCHSCREEN_CYTTSP4_CORE -e TOUCHSCREEN_CYTTSP4_I2C \
  -e TOUCHSCREEN_ELAN -e TOUCHSCREEN_EDT_FT5X06 \
  -d CPU_FREQ_DEFAULT_GOV_PERFORMANCE -e CPU_FREQ_DEFAULT_GOV_ONDEMAND \
  -e DRM -m DRM_LIMA -e FB_SUN5I_EINK -m RTL8XXXU \
  --set-str LOCALVERSION '-pb626-eink-builtin'

# 256MiB physical RAM, so a 128MiB default CMA reservation is excessive.
"$c" --file linux/.config --set-val CMA_SIZE_MBYTES 32
make -C linux olddefconfig

for key in USB USB_GADGET USB_MUSB_HDRC USB_MUSB_SUNXI USB_MUSB_DUAL_ROLE \
  NOP_USB_XCEIV PHY_SUN4I_USB EXTCON USB_CONFIGFS USB_CONFIGFS_ACM \
  MMC_SUNXI REGULATOR_TPS65185 PWM_SUN4I BACKLIGHT_PWM VIDEO_DEV BLK_DEV_INITRD RD_GZIP \
  CONFIGFS_FS DEVTMPFS DEVTMPFS_MOUNT MMC_BLOCK EXT4_FS ARM_APPENDED_DTB \
  CPU_FREQ_DEFAULT_GOV_ONDEMAND DRM AUTO_ZRELADDR FB_SUN5I_EINK \
  VIDEOBUF2_CORE VIDEOBUF2_V4L2 VIDEOBUF2_MEMOPS VIDEOBUF2_DMA_CONTIG; do
  grep -qx "CONFIG_$key=y" linux/.config || {
    echo "REQUIRED BUILT-IN MISSING: CONFIG_$key=y" >&2
    exit 1
  }
done
grep -qx '# CONFIG_ARM_ATAG_DTB_COMPAT is not set' linux/.config
for key in RTL8XXXU DRM_LIMA; do
  grep -qx "CONFIG_$key=m" linux/.config || {
    echo "REQUIRED MODULE MISSING: CONFIG_$key=m" >&2
    exit 1
  }
done
grep -qx 'CONFIG_CMA_SIZE_MBYTES=32' linux/.config
echo 'Megi A13 USB MUSB/PHY/EXTCON and initramfs configuration verified.'
