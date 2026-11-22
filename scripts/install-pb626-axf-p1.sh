#!/bin/sh
# Run only in the ELAN eMMC backup FEL environment with the verified kit.
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }

[ "$#" -eq 2 ] || fail "Usage: $0 {check|install-root|stage-boot|activate|activate-shim|activate-preload|rollback-boot} CID"
action=$1
case "$action" in
  check|install-root|stage-boot|activate|activate-shim|activate-preload|rollback-boot) ;;
  *) fail "Unknown action: $action" ;;
esac
[ "$(id -u)" -eq 0 ] || fail "Run as root"
[ -f /sys/firmware/devicetree/base/chosen/pb626,emmc-backup ] ||
  fail "Boot the ELAN eMMC backup variant through FEL"

kit=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
case "$kit" in /run/*) ;; *) fail "Extract the kit in RAM under /run" ;; esac
[ "$(stat -f -c %T "$kit")" = tmpfs ] || fail "The kit must be on tmpfs"
(cd "$kit" && sha256sum -c SHA256SUMS)
release=$(cat "$kit/KERNELRELEASE")
[ "$(uname -r)" = "$release" ] || fail "Unexpected FEL kernel release"

disk=/dev/mmcblk2
p1=${disk}p1
p2=${disk}p2
sys=/sys/class/block/mmcblk2
[ "$(cat "$sys/device/type")" = MMC ] &&
  [ "$(cat "$sys/device/name")" = 8WPD3R ] &&
  [ "$(cat "$sys/device/cid")" = "$2" ] &&
  [ "$(cat "$sys/size")" = 15269888 ] &&
  [ "$(cat "$sys/queue/logical_block_size")" = 512 ] &&
  [ "$(cat "$sys/mmcblk2p1/start")" = 1009664 ] &&
  [ "$(cat "$sys/mmcblk2p1/size")" = 14260224 ] &&
  [ "$(cat "$sys/mmcblk2p2/start")" = 73728 ] &&
  [ "$(cat "$sys/mmcblk2p2/size")" = 65536 ] ||
  fail "Wrong eMMC identity or partition layout"

for node in "$disk" "${disk}"p* "${disk}"boot*; do
  [ -b "$node" ] || continue
  [ "$(blockdev --getro "$node")" = 1 ] || fail "$node must start read-only"
  devnum=$(cat "/sys/class/block/${node##*/}/dev")
  if awk -v dev="$devnum" '$3 == dev { found=1 } END { exit !found }' /proc/self/mountinfo ||
     awk -v node="$node" '$1 == node { found=1 } END { exit !found }' /proc/swaps; then
    fail "$node is in use"
  fi
done

check_stage() {
  actual=$(dd if="$disk" bs=512 skip="$1" count="$2" 2>/dev/null | sha256sum)
  [ "${actual%% *}" = "$(cat "$kit/$3.sha256")" ] || fail "Factory $3 differs from the dump"
}
check_stage 16 42 bt0
check_stage 38192 448 bt1

mounts=$(mktemp -d /run/pb626-mounts.XXXXXX)
root="$mounts/root"
boot="$mounts/boot"
writable=
boot_temp=
cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$boot_temp" ]; then rm -f "$boot_temp" || status=1; fi
  for target in "$root" "$boot"; do
    if mountpoint -q "$target"; then umount "$target" || status=1; fi
  done
  if [ -n "$writable" ]; then
    blockdev --setro "$writable" || status=1
    blockdev --setro "$disk" || status=1
  fi
  rmdir "$root" "$boot" "$mounts" || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$root" "$boot"

unlock() {
  writable=$1
  blockdev --setrw "$disk"
  blockdev --setrw "$writable"
}

root_type() {
  signature=$(blkid "$p1")
  case "$signature" in
    *' TYPE="vfat"'*) printf 'vfat\n' ;;
    *' TYPE="ext4"'*) printf 'ext4\n' ;;
    *) fail "Unknown p1 filesystem" ;;
  esac
}
check_root() {
  mount -t ext4 -o ro,noload "$p1" "$root"
  [ "$(cat "$root/etc/pb626-image-id")" = pb626-emmc-alpine-v1 ] ||
    fail "Unexpected rootfs"
  [ -x "$root/sbin/pb626-emmc-init" ] &&
    cmp "$kit/pb626-emmc-init" "$root/sbin/pb626-emmc-init" &&
    cmp "$boot/default.wbf" "$root/lib/firmware/pb626/default.wbf" &&
    [ -s "$root/lib/modules/$release/modules.dep" ] &&
    chroot "$root" /bin/sh -n /sbin/pb626-emmc-init ||
    fail "Installed rootfs verification failed"
  umount "$root"
}

check_staged() {
  for file in u-boot.bin pb626-zImage pb626.dtb; do
    cmp "$kit/linux/$file" "$boot/linux/$file"
  done
}

write_boot_file() {
  source=$1
  dest=$2
  boot_temp=$(mktemp "$boot/linux/PBXXXXXX")
  cp "$source" "$boot_temp"
  cmp "$source" "$boot_temp"
  sync
  mv -f "$boot_temp" "$dest"
  boot_temp=
  sync
}

check_preload() {
  cmp "$kit/linux/pb626pre.bin" "$boot/linux/pb626pre.bin"
  cmp "$boot/linux/pb626-zImage" "$boot/linux/pb626z.bin"
  (cd "$boot" && sha256sum -c "$kit/AXF-BOOT-SHA256SUMS")
}

mount -t vfat -o ro "$p2" "$boot"
(cd "$boot" && sha256sum -c "$kit/STOCK-SHA256SUMS")
active="$boot/linux/linux.ini"
if cmp -s "$kit/linux.ini.factory" "$active"; then
  config=factory
elif cmp -s "$kit/linux.ini.chainload" "$active"; then
  config=chainload
elif [ -f "$kit/linux.ini.shim" ] && cmp -s "$kit/linux.ini.shim" "$active"; then
  config=shim
elif [ -f "$kit/linux.ini.preload" ] && cmp -s "$kit/linux.ini.preload" "$active"; then
  config=preload
else
  fail "Unexpected active linux.ini"
fi

case "$action" in
  check)
    fs=$(root_type)
    printf 'p1 filesystem: %s\nActive linux.ini: %s\n' "$fs" "$config"
    df -k "$boot"
    ;;
  install-root)
    [ "$config" = factory ] || fail "Restore factory linux.ini before installing p1"
    [ "$(root_type)" = vfat ] || fail "p1 is no longer factory FAT; use FEL to inspect it"
    command -v mkfs.ext4 >/dev/null
    command -v e2fsck >/dev/null
    unlock "$p1"
    mkfs.ext4 -F -q -E nodiscard -L PB626_ROOT "$p1"
    mount -t ext4 "$p1" "$root"
    tar -xzpf "$kit/pb626-megi-rootfs.tar.gz" -C "$root"
    install -m 755 "$kit/pb626-emmc-init" "$root/sbin/pb626-emmc-init"
    mkdir -p "$root/lib/firmware/pb626"
    install -m 644 "$boot/default.wbf" "$root/lib/firmware/pb626/default.wbf"
    printf 'pb626-emmc-alpine-v1\n' > "$root/etc/pb626-image-id"
    sync
    umount "$root"
    blockdev --setro "$p1"
    blockdev --setro "$disk"
    e2fsck -fn "$p1"
    check_root
    ;;
  stage-boot)
    [ "$config" = factory ] || fail "Factory linux.ini must still be active"
    check_root
    for file in u-boot.bin pb626-zImage pb626.dtb; do
      if [ -e "$boot/linux/$file" ]; then
        cmp "$kit/linux/$file" "$boot/linux/$file" || fail "Conflicting file: $file"
      fi
    done
    umount "$boot"
    unlock "$p2"
    mount -t vfat "$p2" "$boot"
    for file in u-boot.bin pb626-zImage pb626.dtb; do
      [ -e "$boot/linux/$file" ] || write_boot_file "$kit/linux/$file" "$boot/linux/$file"
    done
    umount "$boot"
    mount -t vfat -o ro "$p2" "$boot"
    check_staged
    cmp "$kit/linux.ini.factory" "$active"
    ;;
  activate|activate-shim|activate-preload|rollback-boot)
    if [ "$action" = activate ]; then
      check_root
      check_staged
      next=chainload
    elif [ "$action" = activate-shim ]; then
      check_root
      sed 's@c:\\linux\\bImage@c:\\linux\\pb626ax.bin@' "$kit/linux.ini.factory" | cmp - "$kit/linux.ini.shim"
      [ "$(wc -c < "$kit/linux/pb626ax.bin")" -eq 8388608 ] ||
        fail "The shim must fill the stock AXF segment"
      (cd "$boot" && sha256sum -c "$kit/AXF-BOOT-SHA256SUMS")
      if [ -e "$boot/linux/pb626ax.bin" ]; then
        cmp "$kit/linux/pb626ax.bin" "$boot/linux/pb626ax.bin" || fail "Conflicting factory-address shim"
      fi
      next=shim
    elif [ "$action" = activate-preload ]; then
      check_root
      (cd "$boot" && sha256sum -c "$kit/AXF-BOOT-SHA256SUMS")
      test -s "$kit/linux/pb626pre.bin"
      test "$(wc -c < "$kit/linux/pb626pre.bin")" -le 8388608
      test "$(wc -c < "$boot/linux/pb626-zImage")" -le 8388608
      test "$(wc -c < "$boot/linux/pb626.dtb")" -le 65536
      awk '
        BEGIN { ORS = "\r\n" }
        { sub(/\r$/, "") }
        /^img_name = / { sub(/bImage$/, "pb626pre.bin") }
        /^\[script_info\]$/ {
          print "[segment]", "img_name = c:\\linux\\pb626z.bin", "img_size = 0x800000", "img_base = 0x42000000", ""
          print "[segment]", "img_name = c:\\linux\\pb626.dtb", "img_size = 0x10000", "img_base = 0x43200000", ""
        }
        { print }
      ' "$kit/linux.ini.factory" | cmp - "$kit/linux.ini.preload"
      [ ! -e "$boot/linux/pb626pre.bin" ] ||
        cmp "$kit/linux/pb626pre.bin" "$boot/linux/pb626pre.bin"
      [ ! -e "$boot/linux/pb626z.bin" ] ||
        cmp "$boot/linux/pb626-zImage" "$boot/linux/pb626z.bin"
      next=preload
    else
      next=factory
    fi
    if [ "$config" != "$next" ]; then
      umount "$boot"
      unlock "$p2"
      mount -t vfat "$p2" "$boot"
      cmp "$kit/linux.ini.$config" "$active"
      if [ "$next" = shim ] && [ ! -e "$boot/linux/pb626ax.bin" ]; then
        write_boot_file "$kit/linux/pb626ax.bin" "$boot/linux/pb626ax.bin"
        umount "$boot"
        mount -t vfat -o ro "$p2" "$boot"
        cmp "$kit/linux/pb626ax.bin" "$boot/linux/pb626ax.bin"
        umount "$boot"
        mount -t vfat "$p2" "$boot"
        cmp "$kit/linux.ini.$config" "$active"
      elif [ "$next" = preload ]; then
        [ -e "$boot/linux/pb626pre.bin" ] ||
          write_boot_file "$kit/linux/pb626pre.bin" "$boot/linux/pb626pre.bin"
        [ -e "$boot/linux/pb626z.bin" ] ||
          write_boot_file "$boot/linux/pb626-zImage" "$boot/linux/pb626z.bin"
        umount "$boot"
        mount -t vfat -o ro "$p2" "$boot"
        check_preload
        umount "$boot"
        mount -t vfat "$p2" "$boot"
        cmp "$kit/linux.ini.$config" "$active"
      fi
      write_boot_file "$kit/linux.ini.$next" "$active"
      umount "$boot"
      mount -t vfat -o ro "$p2" "$boot"
    fi
    cmp "$kit/linux.ini.$next" "$active"
    if [ "$next" = shim ]; then
      cmp "$kit/linux/pb626ax.bin" "$boot/linux/pb626ax.bin"
    elif [ "$next" = preload ]; then
      check_preload
    fi
    ;;
esac
printf '%s complete\n' "$action"
