#!/usr/bin/env bash
# Build native PE x64 tools on an MSYS2 UCRT64 CI runner. No MSYS runtime
# is shipped to the user. Use the exact laboratory FEL patch.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "${1:?output directory}")
test ! -e "$out"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rev=0237931bb3d66de17c441a3c94d0e4b39e1308d1
git init -q "$work/src"
git -C "$work/src" fetch -q --depth=1 https://github.com/linux-sunxi/sunxi-tools.git "$rev"
git -C "$work/src" -c core.autocrlf=false checkout -q --detach FETCH_HEAD
cd "$work/src"
test "$(git rev-parse HEAD)" = "$rev"
git apply --check "$repo/patches/sunxi-fel-keep-mmu-off.patch"
git apply "$repo/patches/sunxi-fel-keep-mmu-off.patch"
printf '%s\n' '7b097c7148faf1032cf78d31ee25832d08556a61f89cd23dd234b0aa2508274e  fel.c' '76195e9312a81b5461785982300803a7d8b22fa5feb6a023b56df3a054baf61a  fel_lib.c' | sha256sum -c -
printf '#define VERSION "v1.4.2"\n' >version.h
# Force the Windows branch, but use DLLs rather than assuming all MSYS2
# dependencies ship static archives. Collect the transitive PE imports.
make -o version.h OS=Windows_NT CC=gcc LDFLAGS=-static-libgcc sunxi-fel
cp sunxi-fel.exe "$out/"
cp /ucrt64/bin/openssl.exe "$out/"
cp /ucrt64/bin/fdtget.exe "$out/"
printf '%s\n' "$rev" >"$out/SUNXI-TOOLS-REV"
tar --exclude=.git --exclude=sunxi-fel.exe -czf "$out/sunxi-tools-source.tar.gz" .
mkdir "$out/licenses"
# Each DLL copied must come from UCRT64. Fail if a tool depends on MSYS
# or a non-system DLL that cannot be located in the chosen toolchain.
declare -A checked
queue=(sunxi-fel.exe openssl.exe fdtget.exe)
while (( ${#queue[@]} )); do
    name=${queue[0]}; queue=("${queue[@]:1}")
    [ -z "${checked[${name,,}]:-}" ] || continue
    checked[${name,,}]=1
    mapfile -t deps < <(objdump -p "$out/$name" | awk '/DLL Name:/ {print $3}')
    (("${#deps[@]}">0))
    for dll in "${deps[@]}"; do
        case "${dll,,}" in
            msys-*.dll|cygwin*.dll) echo "Non-native dependency $dll" >&2; exit 1 ;;
        esac
        if [ -f "/ucrt64/bin/$dll" ]; then
            cp "/ucrt64/bin/$dll" "$out/"
            queue+=("$dll")
        else
            case "${dll,,}" in
                api-ms-win-*.dll|ext-ms-win-*.dll|kernel32.dll|kernelbase.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|advapi32.dll|bcrypt.dll|bcryptprimitives.dll|crypt32.dll|ws2_32.dll|user32.dll|gdi32.dll|shell32.dll|shlwapi.dll|ole32.dll|oleaut32.dll|setupapi.dll|cfgmgr32.dll|winusb.dll|winmm.dll|normaliz.dll|iphlpapi.dll|secur32.dll|version.dll|comdlg32.dll|rpcrt4.dll|psapi.dll|hid.dll|mswsock.dll|dnsapi.dll|ncrypt.dll|wintrust.dll|powrprof.dll) ;;
                *) echo "Unknown dependency $dll" >&2; exit 1 ;;
            esac
        fi
    done
    package=$(pacman -Qoq "/ucrt64/bin/$name" 2>/dev/null || :)
    if [ -n "$package" ]; then
        pacman -Q "$package" >>"$out/licenses/packages.txt"
        for dir in $(pacman -Qlq "$package" | grep '/share/licenses/[^/]*/$' || :); do
            [ -d "$dir" ] && cp -r "$dir" "$out/licenses/" || :
        done
    fi
done
(cd "$out" && ./sunxi-fel.exe --list-socs | grep -E '1625: A13')
printf '%s\n' 'Native UCRT64 build; hardware USB qualification remains necessary.' >"$out/QUALIFICATION.txt"
