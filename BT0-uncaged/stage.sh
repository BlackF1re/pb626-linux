#!/bin/sh
# PB626 ELAN/eMMC only. No write beyond LBA16..63.
set -eu
D=/run/bt0-uncaged
cd "$D"
DEV=/dev/mmcblk2
SYS=/sys/class/block
MODE=${1:-status}
CID=${2:?Explicit target CID required}
case "$CID" in *[!0-9a-f]*|'') exit 2;; esac
test "${#CID}" -eq 32
case "$MODE" in status|install|rollback) ;; *) exit 2;; esac
if [ "$MODE" = install ]; then test "${3:-}" = --accept-no-recovery; fi
OLD=6a3fcb2ed0c95d01799df6c9c3e7a3e6ed1045e4028fe1164a9ba44a81b56f4f
NEW=f1ddc645769b6db0d3da88d3510d17acd449184310a07084c23ec499bb2eabf6
RAW=6b73744d7e3962758b93ac94030fc5910b3dcbd08b1c54d684687bcc7e4e3605
BT1=3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227
SPL=39e4a51962e7288ddbef7dcecfbf508d43e23d3e59b2e970896dd2393f9824ae
check() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
read_extent() {
  dd if="$DEV" of="$3" bs=512 skip="$1" count="$2"
  test "$(wc -c < "$3")" -eq "$((512 * $2))"
}
verify_other() {
  read_extent 80 14894 other.bin; check "$RAW" other.bin
  read_extent 38192 448 other.bin; check "$BT1" other.bin
  read_extent 38704 448 other.bin; check "$BT1" other.bin
  rm -f other.bin
}
check "$OLD" factory-first80.bin
check "$SPL" BT0-uncaged.bin
test "$(wc -c < factory-first80.bin)" -eq 40960
test "$(wc -c < BT0-uncaged.bin)" -eq 24576
test -b "$DEV"
test "$(cat "$SYS/mmcblk2/device/cid")" = "$CID"
test "$(cat "$SYS/mmcblk2/ro")" = 0
test "$(cat "$SYS/mmcblk2/queue/logical_block_size")" = 512
test "$(cat "$SYS/mmcblk2p1/start")" = 1009664
test "$(cat "$SYS/mmcblk2p1/size")" = 14260224
test "$(cat "$SYS/mmcblk2p2/start")" = 73728
test "$(cat "$SYS/mmcblk2p2/size")" = 65536
rootdev=$(cat "$SYS/mmcblk2p1/dev")
awk -v dev="$rootdev" '$3==dev && $5=="/" && $0 ~ / - ext4 / {ok=1} END {exit !ok}' /proc/1/mountinfo
# Build complete expected 40 KiB prefix only in RAM.
dd if=factory-first80.bin of=factory-extent.bin bs=512 skip=16 count=48
cp factory-first80.bin expected-new.bin
dd if=BT0-uncaged.bin of=expected-new.bin bs=512 seek=16 count=48 conv=notrunc
check "$NEW" expected-new.bin
read_extent 0 80 live-prefix.bin
live=$(sha256sum live-prefix.bin | cut -d' ' -f1)
case "$live" in
  "$OLD") state=FACTORY;;
  "$NEW") state=PRIMARY_V2;;
  *) echo "UNEXPECTED_PREFIX $live"; exit 1;;
esac
verify_other
echo "CURRENT_BOOT_PREFIX=$state"
if [ "$MODE" = status ]; then echo PRIMARY_PREFLIGHT_OK; exit 0; fi
case "$MODE:$state" in
  install:FACTORY) target=BT0-uncaged.bin; want=$NEW; before=$OLD;;
  rollback:PRIMARY_V2) target=factory-extent.bin; want=$OLD; before=$NEW;;
  *) echo 'Wrong starting state; nothing written'; exit 1;;
esac
dd if=live-prefix.bin of=before-extent.bin bs=512 skip=16 count=48
test "$(wc -c < before-extent.bin)" -eq 24576
modified=0
cleanup() {
  rc=$?
  trap - EXIT
  if [ "$modified" = 1 ]; then
    echo 'WRITE_OR_VERIFY_FAILED: attempting to restore prior extent; DO NOT REBOOT'
    if dd if=before-extent.bin of="$DEV" bs=512 seek=16 count=48 conv=notrunc && sync && read_extent 0 80 restored.bin && check "$before" restored.bin; then
      echo PRIOR_PREFIX_RESTORED
    else
      echo RESTORE_FAILED_DO_NOT_REBOOT
    fi
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
sync
modified=1
dd if="$target" of="$DEV" bs=512 seek=16 count=48 conv=notrunc
sync
read_extent 0 80 after.bin
check "$want" after.bin
verify_other
sync
modified=0
trap - EXIT HUP INT TERM
if [ "$MODE" = install ]; then echo PRIMARY_V2_INSTALLED_VERIFIED; else echo FACTORY_BT0_RESTORED_VERIFIED; fi
