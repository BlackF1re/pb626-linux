#!/usr/bin/env bash
# Run in a Debian armhf build environment (native or QEMU). QEMU is only
# used to establish correctness and ELF sizes, never target timing.
set -Eeuo pipefail
export LC_ALL=C
repo=$(cd "$(dirname "$0")/.." && pwd)
uapi=$(realpath "${1:?kernel UAPI directory}")
out=$(realpath -m "${2:?report/output directory}")
mkdir -p "$out"
cd "$repo"
selected=${3:-all}
case "$selected" in all|pb626-epd|pb626-x11-epd|pb626-charge) ;; *) echo "Unknown program: $selected" >&2; exit 2 ;; esac
printf 'Starting compiler audit: %s\n' "$selected"
test "$(dpkg --print-architecture)" = armhf
test -s "$uapi/linux/sun5i-eink.h"
cc -v >"$out/compiler.txt" 2>&1
cc -Q -O2 --help=target >>"$out/compiler.txt"
cc -Q -O2 --help=optimizers >>"$out/compiler.txt"
dpkg-buildflags --status >>"$out/compiler.txt"
printf 'profile\tprogram\tresult\tstripped_bytes\ttext\tdata\tbss\n' >"$out/results.tsv"
warnings=(-Wall -Wextra -Werror)
xlibs=(-lX11 -lXext -lXtst -lXdamage -lXfixes -lXrandr -lm)
cpu=(-mcpu=cortex-a8 -mfpu=neon -mfloat-abi=hard)
read -ra cppflags <<< "$(dpkg-buildflags --get CPPFLAGS)"
read -ra cflags <<< "$(dpkg-buildflags --get CFLAGS)"
read -ra ldflags <<< "$(dpkg-buildflags --get LDFLAGS)"
# Each candidate is independent of the default firmware flags.
run_one() {
    local program=$1 profile=$2
    shift 2
    local dir="$out/$profile/$program" source test_source
    local -a includes=() libs=() test_args=()
    case "$program" in
        pb626-epd)
            source=display/pb626-epd.c
            test_source=display/test-pb626-epd.c
            includes=(-I "$uapi") ;;
        pb626-x11-epd)
            source=display/pb626-x11-epd.c
            test_source=display/test-pb626-x11-epd.c
            libs=("${xlibs[@]}") ;;
        pb626-charge)
            source=boot/debian/pb626-charge.c
            test_source=$source
            test_args=(--self-test) ;;
    esac
    mkdir -p "$dir"
    printf '%q ' cc "$@" >"$dir/flags.txt"
    printf '\n' >>"$dir/flags.txt"
    printf '[%s] %s: compiling and testing\n' "$program" "$profile"
    if ! {
        cc "${warnings[@]}" "${includes[@]}" "$@" "$source" -o "$dir/program" "${libs[@]}" &&
        cc "${warnings[@]}" "${includes[@]}" "$@" "$test_source" -o "$dir/test" "${libs[@]}" &&
        "$dir/test" "${test_args[@]}" &&
        readelf -h -A -l -d "$dir/program" >"$dir/elf.txt" &&
        strip "$dir/program"
    } >"$dir/build.log" 2>&1; then
        printf '%s\t%s\tfailed\t-\t-\t-\t-\n' "$profile" "$program" >>"$out/results.tsv"
        printf '[%s] %s: FAILED\n' "$program" "$profile" >&2
        tail -n 30 "$dir/build.log" >&2
        if [ "$profile" = baseline ] || [ "$profile" = release ]; then return 1; fi
        return 0
    fi
    size -A "$dir/program" >"$dir/sections.txt"
    local sizes
    sizes=$(size "$dir/program" | awk 'NR==2 {printf "%s\t%s\t%s", $1,$2,$3}')
    printf '%s\t%s\tpass\t%s\t%s\n' "$profile" "$program" "$(stat -c %s "$dir/program")" "$sizes" >>"$out/results.tsv"
    printf '[%s] %s: PASS (%s bytes)\n' "$program" "$profile" "$(stat -c %s "$dir/program")"
}
for program in pb626-epd pb626-x11-epd pb626-charge; do
    if [ "$selected" != all ] && [ "$selected" != "$program" ]; then continue; fi
    base=(-O2)
    case "$program" in
        pb626-epd) base=(-O3) ;;
        pb626-x11-epd) base=(-mfpu=neon -O2) ;;
    esac
    run_one "$program" baseline "${base[@]}"
    run_one "$program" tuned "${base[@]}" -mtune=cortex-a8
    run_one "$program" cortex-a8 "${base[@]}" "${cpu[@]}"
    run_one "$program" cortex-a8-o2 "${cpu[@]}" -O2
    run_one "$program" cortex-a8-o3 "${cpu[@]}" -O3
    run_one "$program" cortex-a8-os "${cpu[@]}" -Os
    run_one "$program" cortex-a8-arm "${cpu[@]}" -O2 -marm
    run_one "$program" cortex-a8-thumb "${cpu[@]}" -O2 -mthumb
    run_one "$program" cortex-a8-lto "${cpu[@]}" -O2 -flto
    run_one "$program" cortex-a8-os-lto "${cpu[@]}" -Os -flto
    run_one "$program" cortex-a8-gc "${cpu[@]}" -Os -ffunction-sections -fdata-sections -Wl,--gc-sections
    run_one "$program" debian-hardening "${cppflags[@]}" "${cflags[@]}" "${base[@]}" "${ldflags[@]}"
    release=("${cppflags[@]}" "${cflags[@]}" "${ldflags[@]}" "${base[@]}")
    if [ "$program" = pb626-charge ]; then
        release+=(-Os -ffunction-sections -fdata-sections -Wl,--gc-sections)
    fi
    run_one "$program" release-before-page4k "${release[@]}"
    # Production binaries must pass with the qualified 4 KiB load alignment.
    run_one "$program" release "${release[@]}" -Wl,-z,max-page-size=4096
    run_one "$program" release-page4k "${release[@]}" -Wl,-z,max-page-size=4096
    run_one "$program" release-page4k-common "${release[@]}" -Wl,-z,max-page-size=4096,-z,common-page-size=4096
    for profile in baseline release-before-page4k release release-page4k-common; do
        if [ -s "$out/$profile/$program/elf.txt" ]; then
            printf '\n[%s] %s ELF load segments:\n' "$program" "$profile"
            grep -E 'LOAD|GNU_RELRO|GNU_STACK|INTERP' "$out/$profile/$program/elf.txt" || :
        fi
    done
done
cat "$out/compiler.txt"
cat "$out/results.tsv"
