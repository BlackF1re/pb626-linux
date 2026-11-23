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
# Keep Mesa assertions active while diagnosing GLES context initialization.
meson setup build --wrap-mode=nofallback --prefix="$prefix" --libdir=lib \
    --buildtype=debugoptimized -Db_ndebug=false --strip \
    -Dgallium-drivers=lima -Dvulkan-drivers=[] -Dplatforms=[] \
    -Degl=enabled -Degl-native-platform=surfaceless -Dgles2=enabled \
    -Dgles1=disabled -Dglx=disabled -Dopengl=true -Dgbm=disabled \
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
cp docs/license.rst "$stage/Mesa-license.rst"
cp -r licenses "$stage/Mesa-licenses"
tar -C /tmp/overlay -czf /mesa-cache/mesa-lima.tar.gz opt/pb626-lima
