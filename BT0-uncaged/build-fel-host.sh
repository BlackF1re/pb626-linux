#!/usr/bin/env bash
# Build the recovered laboratory entry and patched host tool independently
# of the still-unqualified source-built U-Boot SPL. No device access.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(realpath -m "$1")
test ! -e "$out"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang --target=armv7a-none-eabi -c "$here/fel-entry.S" -o "$work/entry.o"
ld.lld -Ttext=0x41000000 -e _start "$work/entry.o" -o "$work/entry.elf"
llvm-objcopy -O binary -j .text "$work/entry.elf" "$out/direct-entry.bin"
(cd "$out" && echo '1a0044b4533ce91bb1f19f5fef9f1356242d3855cadd4087cc1c6a6ac22a21dd  direct-entry.bin' | sha256sum -c -)
rev=0237931bb3d66de17c441a3c94d0e4b39e1308d1
git init -q "$work/git"
git -C "$work/git" fetch -q --depth=1 https://github.com/linux-sunxi/sunxi-tools.git "$rev"
test "$(git -C "$work/git" rev-parse FETCH_HEAD)" = "$rev"
mkdir "$work/source"
git -C "$work/git" archive FETCH_HEAD | tar -x -C "$work/source"
cd "$work/source"
git apply --check "$here/../patches/sunxi-fel-keep-mmu-off.patch"
git apply "$here/../patches/sunxi-fel-keep-mmu-off.patch"
# These are the SHA256s of the actual two modified laboratory sources.
printf '%s\n' \
 '7b097c7148faf1032cf78d31ee25832d08556a61f89cd23dd234b0aa2508274e  fel.c' \
 '76195e9312a81b5461785982300803a7d8b22fa5feb6a023b56df3a054baf61a  fel_lib.c' | sha256sum -c -
printf '/* Auto-generated information. DO NOT EDIT */\n#define VERSION "v1.4.2"\n' > version.h
# Include corresponding source with the distributed executable.
tar -czf "$out/sunxi-tools-source.tar.gz" .
make -o version.h sunxi-fel
./sunxi-fel --help >"$out/sunxi-fel-help.txt" 2>&1
./sunxi-fel --list-socs >"$out/sunxi-fel-socs.txt"
grep -Eq '1625: A13' "$out/sunxi-fel-socs.txt"
install -m 755 sunxi-fel "$out/sunxi-fel"
printf '%s\n' "$rev" > "$out/SUNXI-TOOLS-REV"
printf '%s\n' 'Source-identical lab changes; new host binary still requires physical USB qualification.' >"$out/QUALIFICATION.txt"
(cd "$out" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' | sort -z | xargs -0 sha256sum > SHA256SUMS)
