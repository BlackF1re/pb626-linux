#!/bin/sh
# Known-image updater for the physically validated layout only.
set -eu
cd /run/pb626-mbus-install
DEV=/dev/mmcblk2
SYS=/sys/class/block
COUNT=14959
SIZE=$((COUNT*512))
PREFIX=2673c7b186a731b8b429812f4d55340c054fbbd5c42e0582b3a06794e12e8b63
OLD=5f98e5c1b946ef50e9331074494191f6df5b3f662be28b627ea184598538e301
NEW=33380f0bf21a7ba8b0480d7c545609bf0c05b9b5999c8bf3cced9dd16283384e
BT1=3698c3aa4e809898bdbebd172a66b9214872235d8dc6680363335cdf29c30227
REL=7.2.0-pb626-eink-builtin-mbusfix-gfacc87117511-dirty
OLDREL=7.2.0-gfacc87117511-dirty
MODE=$1
CID=$2
case "$CID" in *[!0-9a-f]*|'') exit 2;; esac
test "$(printf '%s' "$CID" | wc -c)" -eq 32
case "$MODE" in status|install|rollback) ;; *) exit 2;; esac
check() { printf '%s  %s\n' "$1" "$2" | sha256sum -c -; }
read_extent() { dd if="$DEV" of="$3" bs=512 skip="$1" count="$2" && test "$(wc -c < "$3")" -eq "$((512*$2))"; }
verify_other() {
  read_extent 0 80 protected.bin && check "$PREFIX" protected.bin &&
  read_extent 38192 448 protected.bin && check "$BT1" protected.bin &&
  read_extent 38704 448 protected.bin && check "$BT1" protected.bin &&
  rm -f protected.bin
}
require() {
  label=$1; shift
  if "$@"; then printf 'CHECK %s: OK\n' "$label";
  else printf 'CHECK %s: FAIL; no write attempted\n' "$label" >&2; exit 1; fi
}
require BLOCK_DEVICE test -b "$DEV"
require CID test "$(cat "$SYS/mmcblk2/device/cid")" = "$CID"
require WRITABLE test "$(cat "$SYS/mmcblk2/ro")" = 0
require SECTOR_SIZE test "$(cat "$SYS/mmcblk2/queue/logical_block_size")" = 512
require P1_START test "$(cat "$SYS/mmcblk2p1/start")" = 1009664
require P1_SIZE test "$(cat "$SYS/mmcblk2p1/size")" = 14260224
require P2_START test "$(cat "$SYS/mmcblk2p2/start")" = 73728
require P2_SIZE test "$(cat "$SYS/mmcblk2p2/size")" = 65536
require P3_EXTENDED_START test "$(cat "$SYS/mmcblk2p3/start")" = 1
require P3_EXTENDED_SIZE test "$(cat "$SYS/mmcblk2p3/size")" = 2
for part in "$SYS"/mmcblk2p*; do
  name=$(basename "$part")
  if [ "$name" = mmcblk2p3 ]; then continue; fi
  require "BOUNDARY_$name" test "$(cat "$part/start")" -ge $((80+COUNT))
done
rootdev=$(cat "$SYS/mmcblk2p1/dev")
require ROOT_MOUNT awk -v dev="$rootdev" '$3==dev && $5=="/" && $0 ~ / - ext4 / {ok=1} END {exit !ok}' /proc/1/mountinfo
require IMAGE_ID test "$(cat /etc/pb626-image-id)" = pb626-native-alpine-v1
require OLD_MODULES test -d "/lib/modules/$OLDREL"
require NEW_MODULES_DEP test -s "/lib/modules/$REL/modules.dep"
require BUILTIN_EINK grep -Fxq kernel/drivers/video/fbdev/sun5i-eink.ko "/lib/modules/$REL/modules.builtin"
verify_other
read_extent 80 "$COUNT" before.bin
live=$(sha256sum before.bin | cut -d ' ' -f1)
case "$live" in "$OLD") state=OLD;; "$NEW") state=NEW;; *) echo "UNEXPECTED_FULL_EXTENT=$live"; exit 1;; esac
echo "CURRENT_RAW_IMAGE=$state"
echo "CURRENT_FULL_EXTENT=$live"
if [ "$MODE" = status ]; then echo MBUS_INSTALL_PREFLIGHT_OK; exit 0; fi
case "$MODE:$state" in
  install:OLD) target=raw-linux-mbusfix.img; want=$NEW; test "$(uname -r)" = "$REL"; test -c /dev/video0; pidof Xorg >/dev/null; pidof pb626-epd >/dev/null;;
  rollback:NEW) target=raw-linux-fast-rollback.img; want=$OLD;;
  *) echo 'Wrong starting state; nothing written'; exit 1;;
esac
test "$(wc -c < "$target")" -eq "$SIZE"
check "$want" "$target"
check "$live" before.bin
backup=/root/pb626-raw-before-$state-$live.img
if [ -e "$backup" ]; then check "$live" "$backup"; else cp before.bin "$backup.tmp"; check "$live" "$backup.tmp"; mv "$backup.tmp" "$backup"; fi
sync
modified=0
cleanup() {
  rc=$?; trap - EXIT; trap '' HUP INT TERM
  if [ "$modified" = 1 ]; then
    echo 'WRITE_OR_VERIFY_FAILED: restoring prior extent; DO NOT REBOOT'
    if dd if=before.bin of="$DEV" bs=512 seek=80 count="$COUNT" conv=notrunc && sync && read_extent 80 "$COUNT" after.bin && check "$live" after.bin && verify_other; then echo PRIOR_RAW_IMAGE_RESTORED; else echo RESTORE_FAILED_DO_NOT_REBOOT; fi
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
read_extent 80 "$COUNT" check-before.bin; check "$live" check-before.bin; rm check-before.bin
modified=1
dd if="$target" of="$DEV" bs=512 seek=80 count="$COUNT" conv=notrunc
sync
read_extent 80 "$COUNT" after.bin; check "$want" after.bin
verify_other
sync
modified=0
trap - EXIT HUP INT TERM
if [ "$MODE" = install ]; then echo MBUS_KERNEL_INSTALLED_VERIFIED; else echo MBUS_KERNEL_ROLLBACK_VERIFIED; fi
