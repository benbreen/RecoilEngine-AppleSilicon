#!/bin/bash
# Generate the fleet libm reference that build-engine.sh's parity gate compares
# against: testkit/libm-refs/double-fn-vm26.txt (submodule streflop lane).
#
# Why: the gate proves the port's streflop double-precision libm hashes 9/9
# identical to the x86 fleet's. Its reference used to exist only on the
# maintainer's machine, so every fresh clone stopped at "FATAL: libm parity gate
# cannot run" (issue #17). A reference generated from THIS build would be
# circular and prove nothing, so it is produced the way the fleet produces its
# binaries: upstream's own Linux build (docker-build-v2, the CI toolchain image
# pinned by digest in docker-build-v2/images_versions.sh, gcc-13, x86-64) builds
# libstreflop.a, and scripts/dfp-small.cpp is linked against it and run there.
#
# Regenerate after every engine bump that touches rts/lib/streflop, and commit
# the result. Needs Docker (Docker Desktop runs the amd64 image under Rosetta)
# and bash >= 4 for docker-build-v2/build.sh (Homebrew bash).
#
# Usage: gen-libm-ref.sh [-j N]
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="$BAR/testkit/libm-refs/double-fn-vm26.txt"
JOBS=("$@")

BASH4=$(command -v /opt/homebrew/bin/bash || command -v bash)
"$BASH4" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' \
  || { echo "FATAL: docker-build-v2/build.sh needs bash >= 4 (brew install bash)"; exit 1; }

# The submodule lane only: the glibc-import lane (2025.06.24) has its own
# clang-built drift baseline and no fleet gcc reference.
[ -f "$BAR/rts/lib/streflop/libm/dbl-64/w_aliases.cpp" ] \
  && { echo "FATAL: glibc-import streflop lane; this generator covers the submodule lane"; exit 1; }

cd "$BAR"
echo "=== [1/3] configure + build streflop with upstream's amd64-linux CI image ==="
"$BASH4" docker-build-v2/build.sh ${JOBS[@]+"${JOBS[@]}"} --arch amd64 --configure linux
"$BASH4" docker-build-v2/build.sh ${JOBS[@]+"${JOBS[@]}"} --arch amd64 --compile linux --target streflop
ARCHIVE="build-amd64-linux/rts/lib/streflop/libstreflop.a"
[ -f "$ARCHIVE" ] || { echo "FATAL: $ARCHIVE not produced"; exit 1; }

echo "=== [2/3] link + run dfp-small against the fleet archive (same image) ==="
IMAGE=$("$BASH4" -c 'source docker-build-v2/images_versions.sh; echo "ghcr.io/beyond-all-reason/recoil-build-amd64-linux@${image_version[amd64-linux]}"')
mkdir -p "$(dirname "$OUT")"
docker run --platform=linux/amd64 --rm \
  -v "$BAR":/src:ro -v "$BAR/build-amd64-linux":/out:rw \
  "$IMAGE" bash -c '
set -e
# Same forwarding shim build-engine.sh links on the port side (see
# gcc-dbl64-swap.sh): gcc binds mpsqrt.cpp'"'"'s call to an undefined global
# ::fastiroot. It forwards to streflop_libm::fastiroot and changes no math.
SHIM=()
if nm /out/rts/lib/streflop/libstreflop.a 2>/dev/null | grep -q fastiroot; then
  SHIM=(/src/scripts/fastiroot_shim.cpp)
fi
g++-13 -std=c++17 -O2 -DSTREFLOP_SSE -msse -mfpmath=sse -ffp-contract=off \
  -I/src/rts/lib/streflop /src/scripts/dfp-small.cpp "${SHIM[@]}" \
  /out/rts/lib/streflop/libstreflop.a -o /out/dfp-fleet
timeout 120 /out/dfp-fleet
' > "$OUT.tmp"

echo "=== [3/3] sanity ==="
[ "$(wc -l < "$OUT.tmp" | tr -d ' ')" = 9 ] \
  || { echo "FATAL: expected 9 hash lines, got:"; cat "$OUT.tmp"; rm -f "$OUT.tmp"; exit 1; }
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT (streflop $(git -C rts/lib/streflop rev-parse --short HEAD), image ${IMAGE##*@})"
cat "$OUT"
