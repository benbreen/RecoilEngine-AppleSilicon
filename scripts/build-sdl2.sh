#!/bin/bash
# Build real SDL2 (the version the v0.13 release bundles) into
# $DEPS/sdl2-install when Homebrew's "sdl2" is the sdl2-compat shim.
#
# Why: Homebrew replaced its sdl2 formula with sdl2-compat, an SDL2 ABI shim
# over SDL3 that dlopen()s libSDL3.dylib at runtime. release-build.sh bundles
# only what otool -L reports, so the shim would ship without SDL3 and the app
# would fail to start (the hardened runtime ignores DYLD_* fallbacks). It
# would also swap the windowing/input backend under the port's many SDL
# workarounds. v0.13 ships SDL2 2.32.10 (libSDL2-2.0.0.dylib 3201.10.0).
#
# Prints the install prefix for CMAKE_PREFIX_PATH (empty when Homebrew's
# sdl2 is a real SDL2). Called by build-engine.sh.
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPS="$BAR/deps"
SDL2_VER="2.32.10"
PREFIX="$DEPS/sdl2-install"
LIB="$PREFIX/lib/libSDL2-2.0.0.dylib"

BREW_SDL2="$(brew --prefix sdl2 2>/dev/null)/lib/libSDL2-2.0.0.dylib"
if [ -f "$BREW_SDL2" ] && ! LC_ALL=C grep -aq 'libSDL3' "$BREW_SDL2"; then
  exit 0   # a real SDL2 from Homebrew: use it as before
fi
if [ -f "$LIB" ] && [ -f "$PREFIX/lib/cmake/SDL2/SDL2Config.cmake" ]; then
  echo "$PREFIX"; exit 0
fi

{
  mkdir -p "$DEPS"
  SRCDIR="$DEPS/SDL2-$SDL2_VER"
  if [ ! -f "$SRCDIR/CMakeLists.txt" ]; then
    curl -fL --retry 3 -o "$DEPS/SDL2-$SDL2_VER.tar.gz" \
      "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VER/SDL2-$SDL2_VER.tar.gz"
    tar -xzf "$DEPS/SDL2-$SDL2_VER.tar.gz" -C "$DEPS"
  fi
  rm -rf "$SRCDIR/build"
  # prefix maps: keep the builder's path out of SDL's __FILE__ strings
  # (release-build.sh's builder-path audit, LESSON-41)
  PREFIX_MAP="-ffile-prefix-map=$BAR=. -fdebug-prefix-map=$BAR=."
  cmake -S "$SRCDIR" -B "$SRCDIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_OBJC_FLAGS="$PREFIX_MAP" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
  ninja -C "$SRCDIR/build" install
  # SDL installs with an @rpath id; release-build.sh resolves unbundled @rpath
  # deps via /opt/homebrew/lib, which would pick the sdl2-compat shim again.
  # An absolute id makes the bundler copy THIS dylib (and re-id it to @rpath).
  install_name_tool -id "$LIB" "$LIB"
} >&2

test -f "$LIB" || { echo "FATAL: SDL2 build did not produce $LIB" >&2; exit 1; }
echo "$PREFIX"
