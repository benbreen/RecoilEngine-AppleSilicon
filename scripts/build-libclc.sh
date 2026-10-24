#!/bin/bash
# Build libclc (LLVM 19.1.7, the spirv*-mesa3d- targets the pinned Mesa needs)
# into $DEPS/libclc-install when Homebrew's libclc cannot serve the pinned Mesa.
#
# Why: Mesa 26.2-devel @ the pinned commit finds libclc via pkg-config
# (dependency('libclc') -> libexecdir/spirv64-mesa3d-.spv). Newer Homebrew
# libclc (23.x) ships share/clc/<triple>/libclc.spv with no libclc.pc and no
# mesa3d targets, so meson stops with: Dependency "libclc" not found.
# Building it from the LLVM release that matches llvm@19 (the driver's LLVM)
# restores exactly what the pinned Mesa expects.
#
# Prints the pkg-config dir to add to meson's --pkg-config-path (empty when
# Homebrew's libclc is usable as-is). Called by build-mesa-kk.sh.
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPS="$BAR/deps"
LIBCLC_VER="19.1.7"
PREFIX="$DEPS/libclc-install"
PCDIR="$PREFIX/share/pkgconfig"

if pkg-config --exists libclc 2>/dev/null; then
  base=$(pkg-config --variable=libexecdir libclc)
  [ -f "$base/spirv64-mesa3d-.spv" ] && exit 0
fi
if [ -f "$PCDIR/libclc.pc" ] && [ -f "$PREFIX/share/clc/spirv64-mesa3d-.spv" ]; then
  echo "$PCDIR"; exit 0
fi

{
  L19="$(brew --prefix llvm@19)"
  XLAT="$DEPS/spirv-xlat-install/bin/llvm-spirv"
  test -x "$XLAT" || { echo "FATAL: $XLAT missing (build-mesa-kk.sh builds it first)"; exit 1; }
  SRCDIR="$DEPS/libclc-$LIBCLC_VER.src"
  if [ ! -f "$SRCDIR/CMakeLists.txt" ]; then
    curl -fL --retry 3 -o "$DEPS/libclc-$LIBCLC_VER.src.tar.xz" \
      "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LIBCLC_VER/libclc-$LIBCLC_VER.src.tar.xz"
    tar -xf "$DEPS/libclc-$LIBCLC_VER.src.tar.xz" -C "$DEPS"
  fi
  rm -rf "$SRCDIR/build"
  cmake -S "$SRCDIR" -B "$SRCDIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DLLVM_DIR="$L19/lib/cmake/llvm" \
    -DLLVM_SPIRV="$XLAT" \
    -DLIBCLC_TARGETS_TO_BUILD="spirv-mesa3d-;spirv64-mesa3d-" \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++
  ninja -C "$SRCDIR/build" install
} >&2

test -f "$PCDIR/libclc.pc" && test -f "$PREFIX/share/clc/spirv64-mesa3d-.spv" \
  || { echo "FATAL: libclc build did not produce libclc.pc + spirv64-mesa3d-.spv" >&2; exit 1; }
echo "$PCDIR"
