#!/bin/sh
set -eu

prefix=/opt/pb626-lima
apk add --no-cache build-base libdrm-dev libx11-dev expat-dev zlib-dev

mkdir -p /tmp/overlay
tar -C /tmp/overlay -xzf /mesa-cache/mesa-lima.tar.gz
stage=/tmp/overlay$prefix
mkdir -p "$stage/bin"
cc -std=c11 -O2 -Wall -Wextra -Werror -s \
    -I"$stage/include" /src/display/pb626-lima-demo.c -L"$stage/lib" \
    -Wl,-rpath,'$ORIGIN/../lib' -Wl,-rpath-link,"$stage/lib" \
    -o "$stage/bin/pb626-lima-demo" -lEGL -lX11
rm -rf "$stage/include" "$stage/lib/pkgconfig"

for soname in libstdc++.so.6 libgcc_s.so.1 libexpat.so.1 libz.so.1 libdrm.so.2; do
    lib=/usr/lib/$soname
    if [ ! -e "$lib" ]; then
        lib=/lib/$soname
    fi
    cp -L "$lib" "$stage/lib/$soname"
done

cat >"$stage/bin/pb626-lima" <<'EOF'
#!/bin/sh
set -eu
prefix=/opt/pb626-lima
export LD_LIBRARY_PATH="$prefix/lib"
exec "$prefix/bin/pb626-lima-demo" "$@"
EOF
chmod 755 "$stage/bin/pb626-lima"
for binary in "$stage/bin/pb626-lima-demo" "$stage/lib/"*.so*; do
    readelf -h "$binary" | grep -q 'Machine:.*ARM'
    deps=$(LD_LIBRARY_PATH="$stage/lib" ldd "$binary" 2>&1) || {
        printf '%s\n' "$deps" >&2
        exit 1
    }
    printf '%s\n' "$deps"
    if printf '%s\n' "$deps" | grep -Eiq 'LLVM|not found|Error loading'; then
        exit 1
    fi
done

# The Actions container has no Mali render node, so the check must fail closed.
mkdir -p /opt
ln -s "$stage" "$prefix"
if "$prefix/bin/pb626-lima" --verify-only >/tmp/no-gpu.log 2>&1; then
    echo 'The demo accepted an unavailable GPU' >&2
    exit 1
fi
cat /tmp/no-gpu.log
grep -q '^EGL initialization failed' /tmp/no-gpu.log

tar -C /tmp/overlay -czf /out/pb626-lima-armv7.tar.gz opt/pb626-lima
cd /out
sha256sum pb626-lima-armv7.tar.gz >SHA256SUMS
du -sh "$stage" pb626-lima-armv7.tar.gz
