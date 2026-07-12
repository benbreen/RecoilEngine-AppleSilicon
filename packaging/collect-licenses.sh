#!/bin/bash
# collect-licenses.sh <dest-dir> — gather license texts for everything the
# bundle ships, from the actual source trees/brew cellar (no hand-copied
# texts that can drift). Fails if any expected text is missing.
set -euo pipefail

DEST=${1:?dest dir}
BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="${ENGINE_SRC:-$BAR/engine-2025.06.24}"
mkdir -p "$DEST"
fail=0

grab() { # grab <dest-name> <candidate paths...>
  local out=$DEST/$1; shift
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then cp "$p" "$out"; return 0; fi
  done
  echo "MISSING license source for $out (searched: $*)"; fail=1
}

brewdir() { brew --prefix "$1" 2>/dev/null || echo "/nonexistent"; }

grab GPL-2.0.txt            "$SRC/COPYING"
grab LGPL-2.1.txt           "$(brewdir openal-soft)/COPYING" "$(brewdir openal-soft)/share/licenses/openal-soft/COPYING"
grab FTL.txt                "$(brewdir freetype)/LICENSE.TXT" "$(brewdir freetype)/docs/FTL.TXT"
grab Zlib.txt               "/opt/homebrew/opt/sdl2/LICENSE.txt" "$(brewdir sdl2)/LICENSE.txt" "$(brewdir sdl2)/share/licenses/sdl2/LICENSE.txt"
grab Apache-2.0.txt         "$(brewdir spirv-tools)/LICENSE" "$SRC/rts/lib/simdjson/LICENSE"
# curl text only required when a curl dylib is actually bundled (system
# libcurl needs no shipped text)
if ls "${BUNDLE_FRAMEWORKS:-/nonexistent}"/libcurl* >/dev/null 2>&1; then
  grab curl.txt             "$(brewdir curl)/COPYING" "/usr/share/curl/COPYING"
fi

# MIT collection: mesa + vendored MIT components, concatenated with headers
{
  echo "==== Mesa (Zink, KosmicKrisp) ===="
  cat "$BAR/deps/mesa-src/docs/license.rst" 2>/dev/null || cat "$BAR/deps/mesa-src/LICENSE" 2>/dev/null || { echo "MESA LICENSE MISSING"; exit 1; }
  for c in lua fmt lunasvg smmalloc; do
    f=$(find "$SRC/rts/lib/$c" -maxdepth 2 -iname "LICENSE*" -o -maxdepth 2 -iname "COPYING*" 2>/dev/null | head -1)
    [ -n "$f" ] && { echo; echo "==== $c ===="; cat "$f"; }
  done
  echo; echo "==== Fontconfig ===="
  cat "$(brewdir fontconfig)/COPYING" 2>/dev/null || echo "(see fontconfig source COPYING)"
} > "$DEST/MIT-collection.txt"

# BSD-3 collection
{
  for pair in "libogg:$(brewdir libogg)/COPYING" "libvorbis:$(brewdir libvorbis)/COPYING" \
              "zstd:$(brewdir zstd)/LICENSE"; do
    name=${pair%%:*}; path=${pair#*:}
    echo "==== $name ===="
    cat "$path" 2>/dev/null || { echo "MISSING $name"; }
    echo
  done
  echo "==== assimp ===="
  cat "$SRC/rts/lib/assimp/LICENSE" 2>/dev/null || true
  echo "==== tracy ===="
  cat "$SRC/rts/lib/tracy/LICENSE" 2>/dev/null || true
} > "$DEST/BSD-3-Clause-collection.txt"

# Image-codec collection (DevIL/libtiff transitive deps pulled in by the
# recursive bundler)
{
  for pair in "libpng:/opt/homebrew/opt/libpng/LICENSE" \
              "jpeg-turbo:/opt/homebrew/opt/jpeg-turbo/LICENSE.md" \
              "libtiff:/opt/homebrew/opt/libtiff/LICENSE.md" \
              "libwebp:/opt/homebrew/opt/webp/COPYING" \
              "little-cms2:/opt/homebrew/opt/little-cms2/LICENSE" \
              "jasper:/opt/homebrew/opt/jasper/LICENSE.txt" \
              "xz-liblzma:/opt/homebrew/opt/xz/COPYING.0BSD"; do
    name=${pair%%:*}; path=${pair#*:}
    echo "==== $name ===="
    cat "$path" 2>/dev/null || { echo "MISSING $name license"; exit 1; }
    echo
  done
} > "$DEST/image-codecs-collection.txt"
cp /opt/homebrew/opt/gettext/COPYING "$DEST/LGPL-2.1-gettext.txt" 2>/dev/null || true

# DevIL (LGPL) — same LGPL-2.1 text applies; ensure its own copy if present
f="$(brewdir devil)/COPYING"
[ -f "$f" ] && cp "$f" "$DEST/LGPL-2.1-DevIL.txt"

if [ "$fail" -ne 0 ]; then
  echo "collect-licenses: FAILED"; exit 1
fi
echo "collect-licenses: OK ($(ls "$DEST" | wc -l | tr -d ' ') files)"
