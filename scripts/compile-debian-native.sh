#!/usr/bin/env bash
# Compile the native target binaries only; packaging has a separate recipe.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
build=$(realpath "${1:?build chroot}")
kernel=$(realpath "${2:?kernel stage}")
work=$(realpath "${3:?scratch directory}")
cd "$repo"
in_build() { sudo chroot "$build" "$@"; }
sudo install -d "$build/tmp/pb626-build"
sudo install -m 644 display/{pb626-epd.c,pb626-epd.h,pb626-sleep.h,pb626-ddx-fb.h,pb626-x11-epd.c,test-pb626-epd.c,test-pb626-x11-epd.c} "$build/tmp/pb626-build/"
sudo cp -a "$kernel/uapi" "$build/tmp/pb626-build/uapi"
sudo install -m 644 boot/debian/pb626-charge.c "$build/tmp/pb626-build/"
sudo install -m 644 display/{matchbox-keyboard-eink.patch,matchbox-panel-power-supply.patch,xorg-dummy-pb626-shared.patch} "$build/tmp/pb626-build/"

fetch_source() {
    local name=$1 rev=$2 src="$work/src-$1"
    git init -q "$src"
    git -C "$src" fetch -q --depth 1 "https://git.yoctoproject.org/$name" "$rev"
    git -C "$src" checkout -q --detach FETCH_HEAD
    test "$(git -C "$src" rev-parse HEAD)" = "$rev"
    sudo mkdir "$build/tmp/pb626-build/$name"
    git -C "$src" archive HEAD | sudo tar -xf - -C "$build/tmp/pb626-build/$name"
}
fetch_source matchbox-keyboard 630d89068dc0a1e9199306d405cb32f892dfa4d3
fetch_source matchbox-panel 886605280c1032f76e382f68f9a1d2e57012f4db

in_build /bin/bash -euc '
  cd /tmp/pb626-build
  # Use the target distribution ABI and hardening defaults, retaining the
  # measured baseline optimization levels. Test the same flags as release.
  read -ra cppflags <<< "$(dpkg-buildflags --get CPPFLAGS)"
  read -ra cflags <<< "$(dpkg-buildflags --get CFLAGS)"
  read -ra ldflags <<< "$(dpkg-buildflags --get LDFLAGS)"
  native_cc() {
    cc "${cppflags[@]}" "${cflags[@]}" "${ldflags[@]}" -Wall -Wextra -Werror "$@"
  }
  native_cc -O3 -I uapi pb626-epd.c -o pb626-epd
  native_cc -mfpu=neon -O2 pb626-x11-epd.c -o pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lXrandr -lm
  native_cc -O3 -I uapi test-pb626-epd.c -o test-pb626-epd
  native_cc -mfpu=neon -O2 test-pb626-x11-epd.c -o test-pb626-x11-epd -lX11 -lXext -lXtst -lXdamage -lXfixes -lXrandr -lm
  ./test-pb626-epd
  ./test-pb626-x11-epd
  # Charger-only UI spends most of its lifetime waiting for events.
  native_cc -Os -ffunction-sections -fdata-sections -Wl,--gc-sections pb626-charge.c -o pb626-charge
  ./pb626-charge --self-test
  strip pb626-charge
  test "$(./pb626-epd --protocol)" = pb626-epd-shm-4
  strip pb626-epd pb626-x11-epd
  # Build against the actual target Xorg module ABI. The vendor package is
  # retained unmodified, and the private module is not selected by default.
  apt-get source --only-source xserver-xorg-video-dummy=1:0.4.0-1
  cd xserver-xorg-video-dummy-0.4.0
  cp ../pb626-ddx-fb.h src/
  patch --fuzz=0 -p1 < ../xorg-dummy-pb626-shared.patch
  autoreconf -fi
  ./configure --prefix=/usr
  make -j2
  test -s src/.libs/dummy_drv.so
  strip --strip-unneeded src/.libs/dummy_drv.so
  cd ..
  export CFLAGS="-O2 -std=gnu17"
  cd matchbox-keyboard
  patch -p1 < ../matchbox-keyboard-eink.patch
  autoreconf -fi
  ./configure --prefix=/usr --sysconfdir=/etc --disable-shared --enable-static
  make -j2
  make install DESTDIR=/tmp/pb626-build/keyboard-install
  cd ../matchbox-panel
  patch -l -p1 < ../matchbox-panel-power-supply.patch
  autoreconf -fi
  # Old Matchbox relies on libmatchbox transitive X11 dependencies.
  LIBS="$(pkg-config --libs x11 xext xrender xft)" \
    ./configure --prefix=/usr --sysconfdir=/etc --enable-linux-power-supply
  make -j2
  make install DESTDIR=/tmp/pb626-build/panel-install
  strip /tmp/pb626-build/keyboard-install/usr/bin/matchbox-keyboard \
        /tmp/pb626-build/panel-install/usr/bin/matchbox-panel \
        /tmp/pb626-build/panel-install/usr/bin/mb-applet-battery

  # Compare size-oriented builds of the pinned clients without replacing
  # the installed release artifacts. A failed candidate is not selected.
  compare_client() (
    component=$1
    shift
    cd "/tmp/pb626-build/$component"
    case "$component" in
      matchbox-keyboard) release=keyboard-install ;;
      matchbox-panel) release=panel-install ;;
    esac
    candidate="/tmp/pb626-build/audit-$component"
    echo "Matchbox size audit: $component"
    if make clean && make -j2 CFLAGS="-Os -std=gnu17 -ffunction-sections -fdata-sections" LDFLAGS="-Wl,--gc-sections" &&
       make install DESTDIR="$candidate"; then
      for binary in "$@"; do
        base="/tmp/pb626-build/$release/usr/bin/$binary"
        alt="$candidate/usr/bin/$binary"
        if [ -s "$alt" ] && strip "$alt"; then
          echo "Baseline and candidate for $binary:"
          size "$base" "$alt"
          stat -c "%s %n" "$base" "$alt"
          readelf -h -A "$alt"
        else
          echo "Candidate artifact missing: $binary"
        fi
      done
    else
      echo "Compact candidate failed for $component; retaining release"
    fi
  )
  compare_client matchbox-keyboard matchbox-keyboard
  compare_client matchbox-panel matchbox-panel mb-applet-battery
'
