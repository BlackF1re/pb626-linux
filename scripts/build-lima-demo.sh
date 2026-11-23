#!/bin/sh
set -eu

version=26.1.6
prefix=/opt/pb626-lima
archive=mesa-$version.tar.xz
apk add --no-cache build-base meson ninja python3 py3-mako py3-packaging py3-ply \
    py3-yaml pkgconf bison flex curl linux-headers libdrm-dev libx11-dev expat-dev zlib-dev

cd /tmp
curl --fail --location --retry 3 "https://archive.mesa3d.org/$archive" -o "$archive"
echo "5296b88a0f1e012e2cb9ada150a2bbadf728ca81e5a4fb2ab43c83a4d2158606  $archive" |
    sha256sum -c -
tar -xf "$archive"

cd "mesa-$version"
meson setup build --wrap-mode=nofallback --prefix="$prefix" --libdir=lib \
    --buildtype=release --strip \
    -Dgallium-drivers=lima -Dvulkan-drivers=[] -Dplatforms=[] \
    -Degl=enabled -Degl-native-platform=surfaceless -Dgles2=enabled \
    -Dgles1=disabled -Dglx=disabled -Dopengl=false -Dgbm=disabled \
    -Dllvm=disabled -Dglvnd=disabled -Dshader-cache=disabled \
    -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dzstd=disabled \
    -Dbuild-tests=false -Dgallium-va=disabled -Dgallium-rusticl=false
meson compile -C build -j 4

# Mesa 26.1 links Lima into libgallium; it does not install a separate DRI module.
symbols=$(nm --defined-only "build/src/gallium/targets/dri/libgallium-$version.so")
printf '%s\n' "$symbols" | grep -q ' lima_driver_descriptor$' ||
    { echo 'Lima is missing from libgallium' >&2; exit 1; }
if printf '%s\n' "$symbols" | grep -Eq ' (softpipe|llvmpipe)_create_screen$'; then
    echo 'An unexpected software renderer is present in libgallium' >&2
    exit 1
fi
DESTDIR=/tmp/overlay meson install -C build --no-rebuild

stage=/tmp/overlay$prefix
mkdir -p "$stage/bin"
cc -std=c11 -O2 -Wall -Wextra -Werror -s \
    -I"$PWD/include" /src/display/pb626-lima-demo.c -L"$stage/lib" \
    -Wl,-rpath,'$ORIGIN/../lib' -Wl,-rpath-link,"$stage/lib" \
    -o "$stage/bin/pb626-lima-demo" -lEGL -lGLESv2 -lX11
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
cp docs/license.rst "$stage/Mesa-license.rst"
cp -r licenses "$stage/Mesa-licenses"

test -s "$stage/lib/libgallium-$version.so"
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
