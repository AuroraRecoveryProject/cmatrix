#!/bin/bash
set -e

if [ -z "$ANDROID_NDK" ]; then
    echo "ANDROID_NDK is not set"
    exit 1
fi

API=21
TARGET=aarch64-linux-android
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
TOOLCHAIN=$ANDROID_NDK/toolchains/llvm/prebuilt/$HOST_OS-x86_64

export AR=$TOOLCHAIN/bin/llvm-ar
export CC=$TOOLCHAIN/bin/${TARGET}${API}-clang
export CXX=$TOOLCHAIN/bin/${TARGET}${API}-clang++
export RANLIB=$TOOLCHAIN/bin/llvm-ranlib
export STRIP=$TOOLCHAIN/bin/llvm-strip

# Build as PIE so Android ARM64 loader accepts TLS segment alignment.
# We keep ncurses static, but link the final executable as static PIE.
export CFLAGS="-fPIE -fPIC -fno-emulated-tls"
export CPPFLAGS="${CPPFLAGS} -P"
export LDFLAGS="-pie"

NCURSES_VERSION=6.4
if [ ! -d "ncurses-${NCURSES_VERSION}" ]; then
    curl -LO https://ftp.gnu.org/pub/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz
    tar xzf ncurses-${NCURSES_VERSION}.tar.gz
fi

cd ncurses-${NCURSES_VERSION}

CONFIG_ARGS=(
    "--host=$TARGET"
    "--prefix=$PWD/ncurses_install"
    "--without-shared"
    "--without-cxx"
    "--without-cxx-binding"
    "--without-ada"
    "--without-progs"
    "--without-tests"
    "--enable-widec"
    "--with-build-cc=clang"
    "--disable-stripping"
    "--without-manpages"
    "--without-tack"
    "--with-fallbacks=linux,vt100,xterm,xterm-256color"
    "--disable-termcap"
    "--with-ticlib=no"
    "--disable-home-terminfo"
    "--disable-tic-depends"
    "--with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo"
    "--with-default-terminfo-dir=/etc/terminfo"
    "--enable-termcap"
    "--disable-macros"
    "--with-build-cppflags=-D_GNU_SOURCE"
    "--without-fallbacks"
)

CONFIG_SHA_FILE="$PWD/.android_configure.sha"
NEW_SHA=$(printf '%s\n' "${CONFIG_ARGS[@]}" | shasum -a 256 | awk '{print $1}')
OLD_SHA=""
if [ -f "$CONFIG_SHA_FILE" ]; then
    OLD_SHA=$(cat "$CONFIG_SHA_FILE" || true)
fi

if [ ! -f "Makefile" ] || [ "$NEW_SHA" != "$OLD_SHA" ]; then
    make distclean >/dev/null 2>&1 || true
    ./configure "${CONFIG_ARGS[@]}"
    echo "$NEW_SHA" > "$CONFIG_SHA_FILE"
fi

make -j1

# Avoid installing terminfo database on the host during cross-build (can fail
# trying to write /etc/terminfo). We only need headers+static libraries.
make install.libs install.includes
cd ..

mkdir -p build_android
cd build_android

cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-${API} \
    -DCURSES_INCLUDE_DIR=$PWD/../ncurses-${NCURSES_VERSION}/ncurses_install/include \
    -DCURSES_LIBRARY=$PWD/../ncurses-${NCURSES_VERSION}/ncurses_install/lib/libncursesw.a \
    -DCMAKE_EXE_LINKER_FLAGS="-static -pie" \
    -DCMAKE_C_FLAGS="-fPIE -fPIC -fno-emulated-tls -I$PWD/../ncurses-${NCURSES_VERSION}/ncurses_install/include/ncursesw"

make -j8

# Strip the final binary to reduce size for recovery environments.
# Keep this minimal: try strip, but never fail the build if it isn't available.
OUT_BIN="$PWD/cmatrix"
if [ -f "$OUT_BIN" ] && [ -x "${STRIP:-}" ]; then
    echo "Stripping $OUT_BIN ..."
    "${STRIP}" --strip-unneeded "$OUT_BIN" 2>/dev/null || "${STRIP}" -s "$OUT_BIN" 2>/dev/null || true
fi
