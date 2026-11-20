#!/bin/bash
# RAM-only FEL upload of existing lab artifacts. Does not compile or flash eMMC.
set -euo pipefail
lab=${PB626_LAB_DIR:-/root/pb626-lab}
tool=${PB626_FEL_TOOL:-"$lab/retry-tools/sunxi-tools-master/sunxi-fel"}
for file in pb626-spl.bin fel-kernel.zImage direct-board.dtb direct-initramfs.cpio.gz direct-entry.bin; do
    if [[ ! -s "$lab/$file" ]]; then
        printf 'Missing FEL input: %s\n' "$lab/$file" >&2
        exit 1
    fi
done
if [[ ! -x "$tool" ]]; then
    printf 'Missing FEL transport: %s\n' "$tool" >&2
    exit 1
fi
cd "$lab"
export PB626_FEL_KEEP_MMU_OFF=1
exec stdbuf -oL "$tool" -v version spl pb626-spl.bin \
    write 0x42000000 fel-kernel.zImage \
    write 0x43200000 direct-board.dtb \
    write 0x45000000 direct-initramfs.cpio.gz \
    write 0x41000000 direct-entry.bin \
    execute 0x41000000
