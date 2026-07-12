#!/bin/bash
# Recompile streflop's libm/dbl-64 objects with homebrew gcc and swap them into
# the clang-built libstreflop.a.
#
# Why: Recoil's CMake passes -fsingle-precision-constant (gcc-only) on fleet
# builds, demoting every unsuffixed FP literal in dbl-64 (e.g. the correction
# gates `res == res + 1.025*cor` in e_asin) to float precision. Clang has no
# equivalent flag, so a pure-clang build diverges from the x86 fleet in
# double-precision libm results (observed: asin/acos, up to ~45 ulps).
# Compiling these objects with gcc reproduces the fleet's literal semantics
# bit-exactly; NEON vs SSE codegen parity is guaranteed by -ffp-contract=off
# (verified by scripts/double-fn probes).
#
# Usage: gcc-dbl64-swap.sh <build-dir> [gxx]
set -euo pipefail

BUILD=${1:?build dir}
GXX=${2:-/opt/homebrew/bin/g++-15}
SRC_ROOT=$(cd "$(dirname "$0")/.." && pwd)/engine
STREF=$SRC_ROOT/rts/lib/streflop
OBJDIR=$BUILD/rts/lib/streflop/CMakeFiles/streflop.dir/libm/dbl-64
ARCHIVE=$BUILD/rts/lib/streflop/libstreflop.a

[ -x "$GXX" ] || { echo "gcc not found: $GXX"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "archive missing (build streflop first): $ARCHIVE"; exit 1; }

FLAGS=(
  -DASIO_STANDALONE -DMACOSX_BUNDLE -DREPORT_LUANAN -DSPRING_DATADIR='""'
  -DSSE2NEON -DSSE2NEON_SUPPRESS_WARNINGS -DSTREFLOP_NEON -DSYNCCHECK
  -DSYNC_HISTORY -DTHREADPOOL -D_GLIBCXX_USE_NANOSLEEP -DNDEBUG
  -DLIBM_COMPILING_DBL64
  -I"$SRC_ROOT/rts" -I"$SRC_ROOT/rts/lib" -I"$STREF" -I"$STREF/libm/headers"
  -std=c++17 -O2 -fPIC -march=armv8-a
  -fsingle-precision-constant -frounding-math -ffp-contract=off
  -fno-strict-aliasing -fvisibility-inlines-hidden -pthread
  -fno-exceptions -fno-rtti
  -w -Wno-narrowing
)

n=0
for src in "$STREF"/libm/dbl-64/*.cpp; do
  obj=$OBJDIR/$(basename "$src").o
  [ -f "$obj" ] || continue  # only swap objects that are part of the build
  "$GXX" "${FLAGS[@]}" -c "$src" -o "$obj"
  n=$((n+1))
done
ar r "$ARCHIVE" "$OBJDIR"/*.cpp.o 2>/dev/null
ranlib "$ARCHIVE"
echo "swapped $n dbl-64 objects into $ARCHIVE with $GXX"
