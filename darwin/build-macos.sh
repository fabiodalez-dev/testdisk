#!/bin/sh
# Build TestDisk, PhotoRec and fidentify for macOS as universal binaries
# (Apple Silicon arm64 + Intel x86_64). libjpeg-turbo is built from source
# and linked statically, so the binaries only depend on system libraries.
#
# Requirements: Xcode command line tools, autoconf, automake, libtool,
# pkg-config, cmake, git (brew install autoconf automake libtool pkgconf cmake)
#
# Usage: darwin/build-macos.sh            -> universal binaries
#        ARCHS="arm64" darwin/build-macos.sh -> Apple Silicon only
#        BUILD, EXTRA_CPPFLAGS, EXTRA_CONFIGURE: separate build for a front-end
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$SRC/build-macos}
ARCHS=${ARCHS:-"arm64 x86_64"}
MACOS_MIN=${MACOS_MIN:-11.0}
JPEG_TAG=${JPEG_TAG:-3.1.4.1}
JOBS=$(sysctl -n hw.ncpu)

mkdir -p "$BUILD"

if [ ! -x "$SRC/configure" ]; then
  # autopoint refuses to overwrite config/config.rpath, gettext is not used
  (cd "$SRC" && AUTOPOINT=true autoreconf --install -W none -I config)
fi

if [ ! -d "$BUILD/libjpeg-turbo" ]; then
  git clone --depth 1 --branch "$JPEG_TAG" https://github.com/libjpeg-turbo/libjpeg-turbo.git "$BUILD/libjpeg-turbo"
fi

for arch in $ARCHS; do
  prefix="$BUILD/deps-$arch"
  if [ ! -f "$prefix/lib/libjpeg.a" ]; then
    # x86_64 SIMD needs nasm, plain C is enough for PhotoRec
    simd=1
    [ "$arch" = "x86_64" ] && ! command -v nasm >/dev/null 2>&1 && simd=0
    cmake -S "$BUILD/libjpeg-turbo" -B "$BUILD/jpeg-$arch" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$arch" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
      -DCMAKE_INSTALL_PREFIX="$prefix" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DENABLE_SHARED=0 -DENABLE_STATIC=1 -DWITH_SIMD=$simd \
      -DWITH_TURBOJPEG=0 >/dev/null
    cmake --build "$BUILD/jpeg-$arch" -j "$JOBS" >/dev/null
    cmake --install "$BUILD/jpeg-$arch" >/dev/null
  fi

  host=$arch
  [ "$arch" = "arm64" ] && host=aarch64
  mkdir -p "$BUILD/$arch"
  (
    cd "$BUILD/$arch"
    "$SRC/configure" --host="$host-apple-darwin" \
      CC="clang -arch $arch" CXX="clang++ -arch $arch" \
      CFLAGS="-O2 -mmacosx-version-min=$MACOS_MIN" \
      CPPFLAGS="${EXTRA_CPPFLAGS:-}" \
      LDFLAGS="-mmacosx-version-min=$MACOS_MIN" \
      PKG_CONFIG_LIBDIR=/nonexistent \
      --with-jpeg-includes="$prefix/include" --with-jpeg-lib="$prefix/lib" \
      --without-ntfs --without-ntfs3g --without-ewf --without-reiserfs \
      --without-ext2fs --without-iconv --disable-qt ${EXTRA_CONFIGURE:-} >configure.log
    make -j "$JOBS" >make.log 2>&1 || { tail -30 make.log; exit 1; }
  )
done

OUT="$BUILD/dist"
rm -rf "$OUT"
mkdir -p "$OUT"
for prog in testdisk photorec fidentify; do
  set --
  for arch in $ARCHS; do
    set -- "$@" "$BUILD/$arch/src/$prog"
  done
  lipo -create "$@" -output "$OUT/$prog"
  strip "$OUT/$prog"
done
cp "$SRC/COPYING" "$OUT/"
lipo -info "$OUT/photorec"
echo "Binaries in $OUT"
