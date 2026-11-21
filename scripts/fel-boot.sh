#!/usr/bin/env bash
# PocketBook 626 Plus / Touch Lux 3: Megi mainline 7.2 RAM-only FEL uploader.
#
# Why this loader differs from stock sunxi-fel:
#   * The board's BROM starts with MMU enabled. Restoring it after SPL can make
#     the USB FEL transport unusable, so the locally patched FEL tool must
#     honor PB626_FEL_KEEP_MMU_OFF=1 for the *single* SPL command.
#   * A second SPL in the same power cycle is unsafe/unreliable. Power the
#     reader OFF, enter FEL from cold, and run this script only once.
#   * A whole 6 MiB USB write/readback was unreliable under usbipd/WSL. Every
#     image is transferred and verified in independent 64 KiB chunks instead.
#   * The raw ARM entry stub sets r0=0, r1=-1, r2=DTB@0x43200000, and jumps to
#     zImage@0x42000000. It DOES NOT apply U-Boot FDT fixups. DTB must include
#     /memory@40000000 and /chosen/linux,initrd-start/end for RAM initrd.
#   * 'execute' exiting 0 only proves FEL accepted the command. Linux boot is
#     proven only by a 0525:a4a7 USB ACM gadget and working shell (or another
#     independent Linux signature). A blank E Ink screen proves nothing.
#
# Usage: bash fel-boot.sh IMAGE_DIR elan standard|diagnostic [--no-execute]
# Needs in WSL: the audited local SPL + 52-byte stub and patched sunxi-fel;
# kernel, DTB and initramfs come from the pinned Megi CI artifact/diagnostic ZIP.
# Never writes the factory eMMC, internal bootloader, removable microSD or SPI.
set -Eeuo pipefail

if (( $# < 3 || $# > 4 )); then
    echo 'Usage: fel-boot.sh IMAGE_DIR elan|elan-lightoff|elan-usbtest|elan-display|elan-emmc-backup|cypress|focaltech|no-touch standard|diagnostic [--no-execute]' >&2
    exit 2
fi
imgs=${1%/}
variant=$2
profile=$3
option=${4:-}
case "$variant" in elan|elan-lightoff|elan-usbtest|elan-display|elan-emmc-backup|cypress|focaltech|no-touch) ;; *) echo "Invalid variant: $variant" >&2; exit 2;; esac
case "$profile" in
  standard) dtb="pb626-$variant.dtb"; initrd=pb626-megi-initramfs.cpio.gz ;;
  diagnostic) dtb="pb626-$variant.dtb"; initrd=pb626-megi-initramfs.cpio.gz ;;
  *) echo "Invalid profile: $profile" >&2; exit 2 ;;
esac
if [[ -n $option && $option != --no-execute ]]; then
    echo "Invalid option: $option" >&2; exit 2
fi

lab=${PB626_LAB_DIR:-/root/pb626-lab}
fel=${PB626_FEL_TOOL:-$lab/retry-tools/sunxi-tools-master/sunxi-fel}
spl=$lab/pb626-spl.bin
entry=$lab/direct-entry.bin
kernel=$imgs/pb626-megi-zImage
fdt=$imgs/$dtb
ramfs=$imgs/$initrd
manifest=$imgs/SHA256SUMS

for tool in timeout split cmp sha256sum stat awk lsusb; do
    command -v "$tool" >/dev/null || { echo "Missing WSL utility: $tool" >&2; exit 10; }
done
for f in "$fel" "$spl" "$entry" "$kernel" "$fdt" "$ramfs" "$manifest"; do
    [[ -s $f ]] || { echo "Missing FEL input: $f" >&2; exit 11; }
done
[[ -x $fel ]] || { echo "Not executable: $fel" >&2; exit 11; }
[[ $(stat -c '%s' "$entry") -eq 52 ]] || { echo 'Entry stub is not 52 bytes' >&2; exit 11; }

# Authenticity: match the bundle's per-file CI SHA256SUMS. The local SPL and
# entry are not yet published in CI; these are trusted local lab binaries.
check_sha() {
    local file=$1 base expected actual
    base=${file##*/}
    expected=$(awk -v f="$base" '$2 == f {print $1; exit}' "$manifest")
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Missing SHA256SUMS entry: $base" >&2; exit 12; }
    actual=$(sha256sum "$file")
    actual=${actual%% *}
    [[ ${actual,,} == "${expected,,}" ]] || { echo "SHA256 mismatch: $base" >&2; exit 12; }
    echo "SHA256 OK: $base"
}
check_sha "$kernel"
check_sha "$fdt"
check_sha "$ramfs"
command -v fdtget >/dev/null || { echo 'Missing fdtget (device-tree-compiler)' >&2; exit 10; }
if [[ $variant == elan-emmc-backup ]]; then
    [[ $profile == diagnostic ]] || { echo "Backup requires the diagnostic profile" >&2; exit 13; }
    [[ $(fdtget -t s "$fdt" /soc/mmc@1c11000 status) == okay ]] || { echo "Backup requires MMC2" >&2; exit 13; }
    fdtget "$fdt" /chosen pb626,emmc-backup >/dev/null
else
    [[ $(fdtget -t s "$fdt" /soc/mmc@1c11000 status) == disabled ]] || { echo "UNSAFE: MMC2 enabled" >&2; exit 13; }
fi
if [[ $variant == elan-display || $variant == elan-emmc-backup ]]; then
    [[ $(fdtget -t s "$fdt" /soc/mmc@1c0f000 status) == disabled ]] || { echo "UNSAFE: MMC0 enabled" >&2; exit 13; }
fi
[[ $(fdtget -t x "$fdt" /memory@40000000 reg) == "40000000 10000000" ]] || { echo "Wrong RAM FDT" >&2; exit 13; }
fdt_initrd_start=$(fdtget -t x "$fdt" /chosen linux,initrd-start)
fdt_initrd_end=$(fdtget -t x "$fdt" /chosen linux,initrd-end)
[[ ${fdt_initrd_start,,} == 45000000 ]] || { echo "Wrong FDT initrd start" >&2; exit 13; }
(( 16#$fdt_initrd_end == 0x45000000 + $(stat -c '%s' "$ramfs") )) || { echo "Wrong FDT initrd end" >&2; exit 13; }

# A13 physical DDR3 is 0x40000000..0x4fffffff. Do not overwrite another
# image or exceed available RAM, even if the bundle is unexpectedly large.
(( $(stat -c '%s' "$kernel") < 0x43200000 - 0x42000000 )) || { echo 'Kernel overlaps DTB' >&2; exit 13; }
(( $(stat -c '%s' "$fdt") < 0x45000000 - 0x43200000 )) || { echo 'DTB overlaps initramfs' >&2; exit 13; }
(( $(stat -c '%s' "$ramfs") < 0x50000000 - 0x45000000 )) || { echo 'Initramfs exceeds DRAM' >&2; exit 13; }

run=$(mktemp -d)
trap 'rm -rf "$run"' EXIT

echo '===== 1. VERIFY FEL AT COLD BOOT ====='
timeout 15s "$fel" -v version

echo '===== 2. INITIALIZE DRAM: ONE SPL ONLY ====='
PB626_FEL_KEEP_MMU_OFF=1 timeout 40s "$fel" -v version spl "$spl" version

upload_verified() {
    local label=$1 src=$2 base=$3 offset=0 len total address part
    total=$(stat -c '%s' "$src")
    split -b 65536 -d -a 4 "$src" "$run/chunk-"
    echo "===== $label: $total bytes ====="
    for part in "$run"/chunk-*; do
        len=$(stat -c '%s' "$part")
        printf -v address '0x%08x' "$((base + offset))"
        if ! timeout 30s "$fel" write "$address" "$part" \
              read "$address" "$len" "$run/readback"; then
            echo "FEL USB FAILURE: $label offset=$offset address=$address" >&2
            exit 20
        fi
        if ! cmp -s "$part" "$run/readback"; then
            echo "FEL RAM MISMATCH: $label offset=$offset address=$address" >&2
            exit 21
        fi
        offset=$((offset + len))
        if (( offset % 1048576 == 0 || offset == total )); then
            echo "Verified $offset / $total bytes"
        fi
    done
    rm -f "$run"/chunk-*
    echo "SUCCESS: $label"
}
upload_verified 'MAINLINE zImage' "$kernel" 0x42000000
upload_verified "DEVICE TREE $variant" "$fdt" 0x43200000
upload_verified 'RAM INITRAMFS' "$ramfs" 0x45000000
upload_verified 'ARM ENTRY STUB' "$entry" 0x41000000

echo '===== ALL FOUR INPUTS VERIFIED IN RAM ====='
if [[ $option == --no-execute ]]; then
    echo 'NO EXECUTE requested. CPU remains in FEL.'
    exit 0
fi

echo '===== 3. HAND OFF CONTROL TO MEGI ====='
# 0 from execute != proof of running Linux. USB can disconnect as the CPU
# leaves FEL. The host must separately detect gadget VID:PID 0525:a4a7.
set +e
timeout 25s "$fel" -v version execute 0x41000000
status=$?
set -e
echo "FEL execute exit: $status (kernel boot not yet confirmed)"
if (( status != 0 )); then
    echo 'Warning: FEL execute returned nonzero; target state is unknown.' >&2
fi
sleep 12
lsusb || true
echo 'CHECK: Linux requires 0525:a4a7 USB serial (or a separate boot log).'
