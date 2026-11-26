#!/usr/bin/env bash
# Build an independent source candidate. No devices, no writes, never
# automatically replace the hash-qualified historical BT0.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
out=$(realpath -m "${1:?output directory}")
test ! -e "$out"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export CROSS_COMPILE=arm-linux-gnueabihf-
# This exact revision and board defconfig were used by the historical
# .github/workflows/uboot.yml at 4c985f71d4eb333feed023f9bb0d72e5b2dec58e.
rev=96c08df75f632622c57954940d6a1a6c20062e18
git init -q "$work/u-boot"
git -C "$work/u-boot" fetch -q --depth=1 https://codeberg.org/megi/u-boot.git "$rev"
git -C "$work/u-boot" checkout -q --detach FETCH_HEAD
test "$(git -C "$work/u-boot" rev-parse HEAD)" = "$rev"
cd "$work/u-boot"
# Reproduce the historical source fix, not a binary address patch.
sed -i '/rval &= ~SUNXI_MMC_CLK_DIVIDER_MASK;/{N;s/rval &= ~SUNXI_MMC_CLK_DIVIDER_MASK;\n[[:blank:]]*writel(rval, \&priv->reg->clkcr);/clrbits_le32(\&priv->reg->clkcr, SUNXI_MMC_CLK_DIVIDER_MASK);/;}' drivers/mmc/sunxi_mmc.c
grep -F 'clrbits_le32(&priv->reg->clkcr, SUNXI_MMC_CLK_DIVIDER_MASK);' drivers/mmc/sunxi_mmc.c
make pocketbook_touch_lux_3_defconfig
grep -Fx 'CONFIG_SPL=y' .config
cp .config "$out/fel.config"
make -j"$(nproc)" spl/u-boot-spl.bin
# sunxi-spl.bin contains the eGON header; u-boot-spl.bin does not.
make -j"$(nproc)" spl/sunxi-spl.bin
cp spl/sunxi-spl.bin "$out/pb626-fel-spl-candidate.bin"
# Preserve the source for actual DRAM resume review. The upstream
# revision may or may not already implement the Megi RTC contract.
git grep -n -i -E '53555350|SDR_DPCR|STANDBY_GP|super.standby|cpu_resume' -- arch/arm board/sunxi >"$out/resume-audit.txt" || :
cp arch/arm/mach-sunxi/dram_sun4i.c "$out/"
cp arch/arm/mach-sunxi/board.c "$out/sunxi-board.c"
cp configs/pocketbook_touch_lux_3_defconfig "$out/"
# Native candidate: use the existing raw uImage position and the
# existing LRADC hook linked by symbols. Full flash remains gated.
python3 "$here/prepare-source-hook.py" "$PWD"
scripts/config --enable SPL_LEGACY_IMAGE_FORMAT --enable SPL_LEGACY_IMAGE_CRC_CHECK \
    --enable SYS_MMCSD_RAW_MODE_U_BOOT_USE_SECTOR --set-val SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR 0x50 \
    --disable SYS_MMCSD_RAW_MODE_U_BOOT_USE_PARTITION --disable SPL_LOAD_FIT
make olddefconfig
grep -Fx 'CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x50' .config
grep -Fx 'CONFIG_SPL_LEGACY_IMAGE_FORMAT=y' .config
cp .config "$out/native.config"
make -j"$(nproc)" spl/u-boot-spl.bin spl/sunxi-spl.bin
cp spl/sunxi-spl.bin "$out/BT0-uncaged-source-candidate.bin"
"${CROSS_COMPILE}nm" spl/u-boot-spl | grep -E 'pb626_menu_hook|save_boot_params' >"$out/native-symbols.txt"
grep -q pb626_menu_hook "$out/native-symbols.txt"
# Validate eGON length/checksum. Native slot is strictly 24 KiB; a larger
# candidate is retained for review, never accepted by the old assembler.
python3 - "$out" <<'PY'
import pathlib,struct,sys
for p in pathlib.Path(sys.argv[1]).glob("*.bin"):
    b=bytearray(p.read_bytes())
    assert b[4:12]==b"eGON.BT0",p
    n=struct.unpack_from("<I",b,16)[0]
    assert n%512==0 and 0<n<=len(b) and n<=31*1024,p
    want=struct.unpack_from("<I",b,12)[0]
    struct.pack_into("<I",b,12,0x5f0a6c39)
    assert sum(struct.unpack("<%dI"%(n//4),b[:n]))&0xffffffff==want,p
    print(p.name,n,"bytes")
PY
git diff >"$out/uboot-source-changes.patch"
printf '%s\n' "$rev" >"$out/UBOOT-REV"
# Build the other two formerly external FEL inputs from source.
cd "$repo"
"${CROSS_COMPILE}as" "$here/fel-entry.S" -o "$work/entry.o"
"${CROSS_COMPILE}ld" -Ttext=0x41000000 -e _start "$work/entry.o" -o "$work/entry.elf"
"${CROSS_COMPILE}objcopy" -O binary -j .text "$work/entry.elf" "$out/direct-entry-candidate.bin"
git init -q "$work/sunxi-tools"
toolsrev=0237931bb3d66de17c441a3c94d0e4b39e1308d1
git -C "$work/sunxi-tools" fetch -q --depth=1 https://github.com/linux-sunxi/sunxi-tools.git "$toolsrev"
git -C "$work/sunxi-tools" checkout -q --detach FETCH_HEAD
git -C "$work/sunxi-tools" apply --check "$repo/patches/sunxi-fel-keep-mmu-off.patch"
git -C "$work/sunxi-tools" apply "$repo/patches/sunxi-fel-keep-mmu-off.patch"
make -C "$work/sunxi-tools" sunxi-fel
cp "$work/sunxi-tools/sunxi-fel" "$out/"
printf '%s\n' "$toolsrev" >"$out/SUNXI-TOOLS-REV"
(cd "$out" && sha256sum * >SHA256SUMS)
echo 'SOURCE CANDIDATES ONLY: no flash approval; no demonstrated deep resume'
