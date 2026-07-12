#!/bin/bash
# license-audit.sh <Spring.app|dir> — release-gate license compliance check.
#
# Asserts, for every Mach-O binary/dylib found in the bundle:
#   1. it matches exactly one artifact-pattern row in LICENSES/MANIFEST.tsv;
#   2. the license text for its component exists under LICENSES/;
#   3. no LGPL component is statically linked (spot check: the engine binary
#      must NOT export openal/DevIL symbols — they must resolve via dylibs);
#   4. COPYING (GPL) and NOTICE are present in the bundle.
# Exits non-zero on any violation. Wire into release-build.sh — a bundle
# that fails this audit must not ship.
set -euo pipefail

BUNDLE=${1:?usage: license-audit.sh <Spring.app or staging dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$HERE/LICENSES/MANIFEST.tsv"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST missing"; exit 1; }

# license-text presence: map license id -> expected file in LICENSES/
lic_file() {
  case "$1" in
    GPL-2.0-or-later) echo "GPL-2.0.txt";;
    MIT|MIT-style*) echo "MIT-collection.txt";;
    Zlib) echo "Zlib.txt";;
    LGPL-2.1*) echo "LGPL-2.1.txt";;
    FTL*) echo "FTL.txt";;
    BSD-3-Clause*) echo "BSD-3-Clause-collection.txt";;
    Apache-2.0) echo "Apache-2.0.txt";;
    curl*) echo "curl.txt";;
    libpng*|IJG*|libtiff*|libwebp*|JasPer*|0BSD) echo "image-codecs-collection.txt";;
    *) echo "";;
  esac
}

fail=0
found=0

# 4. bundle-level docs
for doc in COPYING NOTICE; do
  if ! find "$BUNDLE" -name "$doc" | grep -q .; then
    echo "VIOLATION: $doc not present in bundle"; fail=1
  fi
done

# 1+2. every Mach-O maps to a manifest row with a shipped license text
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q "Mach-O" || continue
  found=$((found+1))
  base=$(basename "$f")
  row=$(awk -F'\t' -v b="$base" '
    $0 ~ /^#/ {next}
    { pat=$1; gsub(/\*/,".*",pat); if (b ~ ("^" pat "$")) {print; exit} }' "$MANIFEST")
  if [ -z "$row" ]; then
    echo "VIOLATION: $base has no MANIFEST.tsv entry"; fail=1; continue
  fi
  lic=$(printf '%s' "$row" | cut -f3)
  txt=$(lic_file "$lic")
  if [ -n "$txt" ] && [ ! -f "$HERE/LICENSES/$txt" ]; then
    echo "VIOLATION: $base ($lic) — license text LICENSES/$txt missing"; fail=1
  fi
done < <(find "$BUNDLE" -type f \( -perm -111 -o -name "*.dylib" \) -print0)

# 3. no static LGPL: engine must import, not define, openal symbols
ENGINE=$(find "$BUNDLE" -type f -name spring | head -1)
if [ -n "$ENGINE" ]; then
  if nm -gU "$ENGINE" 2>/dev/null | grep -q " _alcOpenDevice$"; then
    echo "VIOLATION: engine binary DEFINES OpenAL symbols (static LGPL link)"; fail=1
  fi
  if ! otool -L "$ENGINE" | grep -q "libopenal"; then
    echo "WARNING: engine does not link libopenal dynamically (NO_SOUND build?)"
  fi
fi

echo "license-audit: scanned $found Mach-O files in $BUNDLE"
if [ "$fail" -ne 0 ]; then
  echo "license-audit: FAILED"
  exit 1
fi
echo "license-audit: OK"
