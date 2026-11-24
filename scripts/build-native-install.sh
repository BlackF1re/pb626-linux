#!/usr/bin/env bash
# Use the Desktop root built from the SAME kernel run. No U-Boot or full
# native initramfs. Installer has a small ARM userspace and compressed root.
set -Eeuo pipefail
bundle=$(realpath "${1:?verified FEL bundle}")
desktop=$(realpath "${2:?completed desktop-root}")
out=$(realpath -m "${3:-native-dist}")
repo=$(pwd)
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT
mkdir -p "$out" "$work/payload" "$work/installer"
installer="$work/installer"
(cd "$bundle" && sha256sum -c SHA256SUMS)
for key in AUTO_ZRELADDR MMC MMC_BLOCK MMC_SUNXI EXT4_FS DEVTMPFS_MOUNT; do
    grep -qx "CONFIG_$key=y" "$bundle/pb626-megi.config"
done
# Uncompressed kernel output must fit below the high payload area.
image_size=$(cat "$bundle/IMAGE_SIZE")
[[ "$image_size" =~ ^[0-9]+$ ]]
(( image_size > 0 && image_size < 0x03ff8000 ))
release=$(cat "$bundle/KERNELRELEASE")
test -d "$desktop/lib/modules/$release"
cp "$bundle/pb626-megi-zImage" "$work/payload/kernel.bin"
cp "$bundle/pb626-elan-emmc-native.dtb" "$work/payload/board.dtb"
dtb="$work/payload/board.dtb"
python3 - "$work/payload" <<'PY'
import pathlib, struct, sys
p=pathlib.Path(sys.argv[1])
def checksum(data):
    data += b'\0' * (-len(data) % 4)
    h=2166136261
    for (w,) in struct.iter_unpack('<I',data):
        h=((h^w)*16777619)&0xffffffff
    return h
k=(p/'kernel.bin').read_bytes()
d=(p/'board.dtb').read_bytes()
assert k[:4]==bytes.fromhex('0000a0e1'), 'Unexpected first zImage instruction'
(p/'payload-check.inc').write_text(
    f'.equ KERNEL_HASH, 0x{checksum(k):08x}\n.equ DTB_HASH, 0x{checksum(d):08x}\n')
PY
test "$(fdtget -t x "$dtb" /memory@40000000 reg)" = '40000000 10000000'
test "$(fdtget -t s "$dtb" /soc/mmc@1c11000 status)" = okay
test "$(fdtget -t s "$dtb" /soc/mmc@1c0f000 status)" = disabled
test "$(fdtget -t s "$dtb" /soc/i2c@1c2b400/touchscreen@15 compatible)" = elan,ektf2227
test "$(fdtget -t s "$dtb" /chosen bootargs)" = 'console=ttyS0,115200 root=/dev/mmcblk2p1 rootfstype=ext4 rootwait rw init=/sbin/init'
fdtget "$dtb" /chosen pb626,display-bringup >/dev/null
fdtget "$dtb" /chosen pb626,emmc-root >/dev/null
! fdtget "$dtb" /chosen pb626,emmc-backup >/dev/null 2>&1
! fdtget "$dtb" /chosen linux,initrd-start >/dev/null 2>&1
! fdtget "$dtb" /chosen linux,initrd-end >/dev/null 2>&1
(
    cd "$work/payload"
    arm-linux-gnueabihf-as "$repo/boot/pb626-native-entry.S" -o entry.o
    arm-linux-gnueabihf-ld -Ttext=0x40008000 -e _start entry.o -o entry.elf
    arm-linux-gnueabihf-objcopy -O binary -j .text entry.elf "$out/pb626.bin"
    arm-linux-gnueabihf-nm -n entry.elf > "$out/ENTRY-MAP.txt"
)
python3 - "$out/pb626.bin" "$work/payload/kernel.bin" "$dtb" "$out/ENTRY-MAP.txt" <<'PY'
import pathlib, struct, sys
payload,kernel,dtb=(pathlib.Path(x).read_bytes() for x in sys.argv[1:4])
syms={}
for line in pathlib.Path(sys.argv[4]).read_text().splitlines():
    addr,kind,name=line.split()
    syms[name]=int(addr,16)
base=0x40008000
assert syms['_start']==base
assert 0<len(payload)<=0x800000
assert len(kernel)>=0x30 and kernel[-4:]==b'\0'*4
magic,start,end=struct.unpack_from('<III',kernel,0x24)
assert magic==0x016f2818 and end-start==len(kernel)-4
assert dtb[:4]==bytes.fromhex('d00dfeed')
assert struct.unpack_from('>I',dtb,4)[0]<=len(dtb)
for name,data in [('kernel',kernel),('dtb',dtb)]:
    lo,hi=(syms[name+'_start']-base,syms[name+'_end']-base)
    assert 0<=lo<hi<=len(payload) and lo%4==hi%4==0
    assert payload[lo:lo+len(data)]==data
    assert 0<=hi-lo-len(data)<4
assert syms['kernel_end']<=syms['dtb_start']
assert 0 < syms['kernel_probe_end']-syms['kernel_probe'] <= 0x1000
assert 0x46000000 + 8 + ((0xfffbfe - 0x1000000) << 2) == 0x45fff000
assert 0x46000000+len(kernel)<0x47000000
assert 0x47000000+len(dtb)<0x47ff0000
assert base+len(payload)<0x42400000
print('Factory payload, ARM zImage header, explicit DTB and disjoint RAM map verified:',len(payload))
PY
# Turn the proven RAM Desktop tree into a persistent, normal BusyBox init root.
# Do not keep old RAM-only init, disposable test WLAN credentials or build tools.
sudo rm -f "$desktop/init" "$desktop/etc/pb626/wpa_supplicant.conf" \
    "$desktop/sbin/pb626-emmc-init"
sudo install -m 755 boot/pb626-native-setup boot/pb626-native-desktop \
    boot/pb626-native-console "$desktop/sbin/"
sudo install -m 644 boot/pb626-native.inittab "$desktop/etc/inittab"
sudo install -d "$desktop/lib/firmware/pb626" "$desktop/home" "$desktop/var/lib/xkb"
printf 'pb626-native-alpine-v1\n' | sudo tee "$desktop/etc/pb626-image-id" >/dev/null
printf '/dev/mmcblk2p1 / ext4 defaults 0 1\nproc /proc proc defaults 0 0\nsysfs /sys sysfs defaults 0 0\n' |
    sudo tee "$desktop/etc/fstab" >/dev/null
test -L "$desktop/sbin/init"
test -x "$desktop/bin/busybox"
for f in usr/bin/Xorg usr/bin/pb626-desktop usr/bin/pb626-epd usr/bin/pb626-x11-epd \
    usr/bin/matchbox-window-manager usr/bin/matchbox-desktop usr/bin/matchbox-keyboard; do
    test -x "$desktop/$f"
done
mkdir -p "$installer"/{bin,sbin,lib,usr/lib,usr/bin,usr/sbin,etc,dev,proc,sys,run,root,opt/pb626-install}
kit="$installer/opt/pb626-install"
# Copy only the three ARM executables and recursively resolve DT_NEEDED.
# Avoid a second complete root in RAM while the compressed desktop is present.
copy_elf() {
    local src=$1 dst=$2 dep found dir
    [[ ! -e "$installer/$dst" ]] || return 0
    sudo install -D -m 755 "$src" "$installer/$dst"
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        found=0
        for dir in lib usr/lib; do
            if [[ -e "$desktop/$dir/$dep" ]]; then
                copy_elf "$desktop/$dir/$dep" "$dir/$dep"
                found=1
                break
            fi
        done
        (( found == 1 )) || { echo "Missing ARM dependency: $dep"; exit 1; }
    done < <(readelf -d "$src" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
}
copy_elf "$desktop/lib/ld-musl-armhf.so.1" lib/ld-musl-armhf.so.1
copy_elf "$desktop/bin/busybox" bin/busybox
copy_elf "$desktop/sbin/mke2fs" sbin/mke2fs
copy_elf "$desktop/sbin/e2fsck" sbin/e2fsck
sudo cp "$desktop/etc/"{passwd,group,mke2fs.conf} "$installer/etc/"
# Supply devices before running the ARM e2fsprogs smoke tests.
sudo mknod -m 666 "$installer/dev/null" c 1 3
sudo mknod -m 666 "$installer/dev/zero" c 1 5
sudo mknod -m 666 "$installer/dev/urandom" c 1 9
sudo install -m 755 /usr/bin/qemu-arm-static "$installer/usr/bin/"
sudo chroot "$installer" /usr/bin/qemu-arm-static /bin/busybox --list > "$work/applets"
while IFS= read -r applet; do
    [[ "$applet" = busybox ]] || sudo ln -s busybox "$installer/bin/$applet"
done < "$work/applets"
for applet in sh blockdev sha256sum tar df mountpoint sed awk dd cmp sync tail setsid gzip reboot; do
    grep -Fxq "$applet" "$work/applets"
done
sudo chroot "$installer" /usr/bin/qemu-arm-static /sbin/mke2fs -V
sudo chroot "$installer" /usr/bin/qemu-arm-static /sbin/e2fsck -V
# Synthetic ext4 test with the exact ARM binaries, never an actual disk.
sudo truncate -s 32M "$installer/test.ext4"
sudo chroot "$installer" /usr/bin/qemu-arm-static /sbin/mke2fs -t ext4 -F -m 0 -E nodiscard /test.ext4
sudo chroot "$installer" /usr/bin/qemu-arm-static /sbin/e2fsck -fn /test.ext4
sudo rm "$installer/test.ext4"
# All normal filesystem content, excluding virtual/runtime directory contents.
sudo tar --format=gnu --numeric-owner \
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' \
    --exclude='./run/*' --exclude='./tmp/*' \
    -C "$desktop" -czf "$kit/rootfs.tar.gz" .
(
    cd "$desktop"
    sudo find . \( -path './dev' -o -path './proc' -o -path './sys' \
        -o -path './run' -o -path './tmp' \) -prune -o -type f -print0 |
        sort -z | sudo xargs -0 -r sha256sum
) >"$kit/ROOT-SHA256SUMS"
# ARM BusyBox must actually read and unpack the produced archive.
sudo chroot "$installer" /usr/bin/qemu-arm-static /bin/busybox tar -tzf /opt/pb626-install/rootfs.tar.gz >"$work/root-list"
grep -Eq '^(\./)?sbin/pb626-native-setup$' "$work/root-list"
grep -Eq '^(\./)?usr/bin/Xorg$' "$work/root-list"
sudo mkdir "$installer/test-root"
sudo chroot "$installer" /usr/bin/qemu-arm-static /bin/busybox \
    tar -xzpf /opt/pb626-install/rootfs.tar.gz -C /test-root
(cd "$installer/test-root" && sudo sha256sum -c "$kit/ROOT-SHA256SUMS" >"$work/root-check")
test -L "$installer/test-root/sbin/init"
sudo rm -rf "$installer/test-root"
sudo rm "$installer/usr/bin/qemu-arm-static"
sudo install -m 755 boot/init-megi "$installer/init"
sudo install -m 755 scripts/install-pb626-emmc.sh "$installer/usr/sbin/install-pb626-emmc"
sudo cp "$out/pb626.bin" "$bundle/KERNELRELEASE" "$kit/"
(cd "$kit" && sha256sum pb626.bin rootfs.tar.gz ROOT-SHA256SUMS KERNELRELEASE >SHA256SUMS)
# Keep simultaneous compressed+expanded initramfs within the 256 MiB budget.
test "$(sudo du -sb "$installer" | cut -f1)" -lt $((64*1024*1024))
(cd "$installer" && sudo find . -print0 | sudo cpio --null --owner=0:0 -o -H newc --quiet) |
    gzip -1 > "$out/pb626-emmc-installer.cpio.gz"
test "$(stat -c %s "$out/pb626-emmc-installer.cpio.gz")" -lt $((64*1024*1024))
cp "$bundle/pb626-elan-emmc-backup.dtb" "$out/pb626-elan-emmc-install.dtb"
install_dtb="$out/pb626-elan-emmc-install.dtb"
fdtput -t x "$install_dtb" /chosen pb626,emmc-install
fdtput -t x "$install_dtb" /chosen linux,initrd-start 45000000
end=$((0x45000000 + $(stat -c %s "$out/pb626-emmc-installer.cpio.gz")))
(( end < 0x50000000 ))
fdtput -t x "$install_dtb" /chosen linux,initrd-end "$(printf '%x' "$end")"
cp "$bundle/pb626-megi-zImage" "$bundle/KERNELRELEASE" "$out/"
cp scripts/{Start-PB626.ps1,Install-PB626.ps1,fel-boot.sh} "$out/"
cp "$dtb" "$out/pb626-elan-emmc-native.dtb"
(cd "$out" && sha256sum pb626* KERNELRELEASE ENTRY-MAP.txt *.ps1 fel-boot.sh >SHA256SUMS)
echo 'Native installer artifact verified (physical cold boot remains untested).'
