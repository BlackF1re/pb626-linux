#!/usr/bin/env bash
# Assemble an independent Windows x64 kit, using only same-run artifacts.
# Standard Linux recovery and the historical hash gate remain unchanged.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
out=$(realpath -m "${1:?output directory}")
test ! -e "$out"
profile=${PB626_WINDOWS_PROFILE:-standard}
case "$profile" in
    standard) candidate=BT0-uncaged-source-candidate.bin; candidate_dir=source-boot-candidates; report_key=native ;;
    deep-lab) candidate=BT0-uncaged-deep-candidate.bin; candidate_dir=source-boot-candidates/deep-resume; report_key=deep_cold_path ;;
    *) exit 2 ;;
esac
for dir in native-stage recovery-stage/recovery windows-host fel-host source-boot-candidates; do
    (cd "$dir" && sha256sum -c SHA256SUMS)
done
rev=$(git rev-parse HEAD)
for file in native-stage/BUILD-COMMIT recovery-stage/recovery/BUILD-COMMIT fel-host/BUILD-COMMIT; do
    test "$(cat "$file")" = "$rev"
done
mkdir -p "$out"/{host,native,recovery,candidate,qualification,source/scripts,source/BT0-uncaged}
printf '%s\n' "$profile" >"$out/PROFILE"
(cd "$candidate_dir" && sha256sum -c SHA256SUMS)
# Include just the usable direct-install payload, not a redundant tarball.
native=(BUILD-COMMIT KERNELRELEASE raw-linux.img pb626-native-zImage pb626-elan-emmc-native.dtb pb626-rootfs.ext4.gz pb626-rootfs.bmap.json pb626-bt0-menu.raw pb626-modules.sha256)
for name in "${native[@]}"; do cp "native-stage/$name" "$out/native/"; done
(cd "$out/native" && sha256sum "${native[@]}" >SHA256SUMS)
cp -a windows-host/. "$out/host/"
cp fel-host/direct-entry.bin "$out/host/"
cp recovery-stage/recovery/{BUILD-COMMIT,pb626-megi-zImage,pb626-megi-initramfs.cpio.gz,pb626-elan-emmc-backup.dtb,pb626-elan-emmc-windows-rndis.dtb,DEBIAN-BUSYBOX-COPYRIGHT} "$out/recovery/"
cp "$candidate_dir/$candidate" "$out/candidate/"
cp qualification/emulation.json "$out/qualification/"
digest=$(sha256sum "$out/candidate/$candidate" | cut -d' ' -f1)
python3 - "$out/qualification/emulation.json" "$digest" "$report_key" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
if r.get("result")!="tested contract passed" or not isinstance(r.get("reference"),dict) or r.get(sys.argv[3],{}).get("sha256")!=sys.argv[2]:
    raise SystemExit("Candidate does not match mandatory differential FEL report")
PY
# Add one immutable authorization file in a second gzip/cpio member.
# Linux initramfs explicitly supports concatenated archives. No external
# peer may supply an arbitrary hash. Keep ordinary recovery unmodified.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/etc"
printf '%s\n' "$digest" >"$work/etc/pb626-spl-candidate.sha256"
printf '%s %s %s\n' "$rev" "$profile" "$digest" >"$work/etc/pb626-windows-build"
chmod 444 "$work/etc/"*
(cd "$work" && printf '%s\0' etc/pb626-spl-candidate.sha256 etc/pb626-windows-build | cpio --null -o --format=newc --owner=0:0 --quiet) | gzip -n -9 >"$work/overlay.gz"
gzip -dc "$work/overlay.gz" | cpio --extract --to-stdout etc/pb626-spl-candidate.sha256 2>/dev/null | grep -Fx "$digest"
cat "$work/overlay.gz" >>"$out/recovery/pb626-megi-initramfs.cpio.gz"
gzip -t "$out/recovery/pb626-megi-initramfs.cpio.gz"
bytes=$(stat -c %s "$out/recovery/pb626-megi-initramfs.cpio.gz")
test "$bytes" -lt 4194304
for dtb in "$out/recovery/"*.dtb; do
    fdtput -t x "$dtb" /chosen linux,initrd-end "$(printf '%x' "$((0x45000000+bytes))")"
    test "$(fdtget -t x "$dtb" /memory@40000000 reg)" = "40000000 10000000"
    test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = okay
    test "$(fdtget -t s "$dtb" /soc/mmc@1c0f000 status)" = disabled
    fdtget "$dtb" /chosen pb626,emmc-backup >/dev/null
done
fdtget "$out/recovery/pb626-elan-emmc-windows-rndis.dtb" /chosen pb626,windows-rndis >/dev/null
if fdtget "$out/recovery/pb626-elan-emmc-backup.dtb" /chosen pb626,windows-rndis >/dev/null 2>&1; then exit 1; fi
(cd "$out/recovery" && sha256sum BUILD-COMMIT *.dtb *.gz pb626-megi-zImage DEBIAN-BUSYBOX-COPYRIGHT >SHA256SUMS)
cp scripts/windows/{PB626.ps1,PB626.cmd,windows-fel.py} "$out/"
cp scripts/installer/{install-direct.py,dump-network.py} "$out/"
cp scripts/{build-native-image.py,pb626_sleep_theme.py} "$out/source/scripts/"
cp BT0-uncaged/build.py "$out/source/BT0-uncaged/"
cp docs/WINDOWS-FLASH.md "$out/README.md"
if [ "$profile" = deep-lab ]; then
    printf '%s\n' 'EXPERIMENTAL DEEP KERNEL + MATCHING MODULES + RESUME SPL. Hardware unqualified. Sleep remains s2idle and qualification-gated.' >"$out/DEEP-LAB-WARNING.txt"
fi
cp LICENSE "$out/"
(cd "$out" && find . -type f ! -path ./SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum >SHA256SUMS && sha256sum -c SHA256SUMS)
