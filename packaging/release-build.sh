#!/bin/bash
# release-build.sh — end-to-end signed/notarized release artifact pipeline.
#
# Produces BAR Launcher.app (staged, signed, optionally notarized) from
# the pinned engine tree + pinned/patched Mesa, with EVERY release gate
# unskippable in-line:
#   build (via scripts/build-engine.sh: -O3 RELWITHDEBINFO, gcc dbl-64 swap,
#   dfp-verify 9/9 fleet-parity gate) → replay smoke → bundle staging →
#   license collection + license-audit → codesign (hardened runtime,
#   get-task-allow FORBIDDEN) → notarize+staple (when identity provided) →
#   ditto zip.
#
# Usage:
#   packaging/release-build.sh [--identity "Developer ID Application: ..."]
#                              [--notary-profile <keychain-profile>]
#                              [--version <tag>] [--skip-replay-smoke]
# Without --identity the bundle is ad-hoc signed (local testing only; will
# not pass Gatekeeper on other machines). Notarization runs only when both
# --identity and --notary-profile are given.
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
PKG="$BAR/packaging"
SRC="${ENGINE_SRC:-$([ -d "$BAR/rts" ] && echo "$BAR" || echo "$BAR/engine-2025.06.24")}"
BUILD="${ENGINE_BUILD:-$BAR/build-engine-2025.06.24-release}"
OUT="${RELEASE_OUT:-$BAR/release-artifacts}"
# release driver prefix: built from the mesa bar-macos branch (never the
# experiments driver the dev/play stack uses)
MESA_PREFIX="${MESA_PREFIX:-$BAR/deps/mesa-native-release}"
IDENTITY="-"           # "-" = ad-hoc
NOTARY_PROFILE=""
# Two versions, two jobs:
#   ENGINE version (e.g. "2025.06.24") — the fleet's pinned identity, the thing
#     lockstep multiplayer keys on (golden rule 5). Read from the built binary
#     after step 1, NOT `git describe`. Kept in CFBundleVersion + EngineVersion
#     so server-side triage stays trivial. --version overrides explicitly.
#   PORT version (e.g. "0.1") — the macOS port's own release number: many port
#     releases ship on one engine pin. Read from packaging/PORT_VERSION;
#     --port-version overrides. This is the user-facing version
#     (CFBundleShortVersionString) and names the artifacts/release tag.
VERSION=""
VERSION_EXPLICIT=0
PORTVER="$(cat "$PKG/PORT_VERSION" 2>/dev/null | tr -d '[:space:]')"
# Release profile:
#   bar    (default) — the engine PLUS the BAR helper: launcher, first-run/
#            every-launch content download from BAR's official network, BAR
#            branding. What players install to play Beyond All Reason.
#   engine — the Recoil engine port alone: signed, notarized engine binaries
#            (spring, spring-headless, pr-downloader) with the bundled driver
#            and dylib closure, no game configuration or branding. For any
#            Spring/Recoil game community, or for building other helpers on.
PROFILE=bar

# Test tiers (mirrors upstream Recoil CI: the *build* workflow only builds +
# packages; heavier validation is separate/opt-in):
#   - sync-test (streflop bit-exactness): CPU-only, seconds, no GPU/content —
#     the cheap determinism guarantee. ON by default; --skip-sync-test drops it
#     for a truly minimal build box.
#   - replay smoke (headless full-game re-sim): needs game content + tens of
#     minutes; this is CERTIFICATION, not a build gate. OFF by default so build
#     machines can package. Opt in with --certify (or RELEASE_CERTIFY=1).
# A shipping artifact should be certified: building a SIGNED bundle without
# certification warns loudly (see below), but does not hard-fail — certify
# separately with `make certify` when the build box can't.
RUN_SYNC_TEST=1
REPLAY_SMOKE=${RELEASE_CERTIFY:-0}

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY=$2; shift 2;;
    --notary-profile) NOTARY_PROFILE=$2; shift 2;;
    --version) VERSION=$2; VERSION_EXPLICIT=1; shift 2;;
    --port-version) PORTVER=$2; shift 2;;
    --profile) PROFILE=$2; shift 2;;
    --certify|--replay-smoke) REPLAY_SMOKE=1; shift;;
    --skip-replay-smoke) REPLAY_SMOKE=0; shift;;   # now the default; kept for compat
    --skip-sync-test) RUN_SYNC_TEST=0; shift;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

case "$PROFILE" in
  bar)    APP="$OUT/BAR Launcher.app";;
  engine) APP="$OUT/Recoil Engine.app";;
  *) echo "unknown --profile: $PROFILE (bar|engine)"; exit 2;;
esac
FRAMEWORKS="$APP/Contents/Frameworks"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
echo "profile: $PROFILE -> $(basename "$APP")"

echo "=== [1/7] gated engine build ($SRC -> $BUILD)"
ENGINE_SRC="$SRC" ENGINE_BUILD="$BUILD" MESA_PREFIX="$MESA_PREFIX" "$BAR/scripts/build-engine.sh"
# build-engine.sh hard-fails unless the streflop archive reproduces the
# lane's libm parity hashes — "bare ninja" output can't reach the steps below.

# Version identity: read it from the binary the fleet will version-check
# against, so the bundle's CFBundleShortVersionString and the artifact names
# are exactly the engine's own version (e.g. "2025.06.24"). Unless --version
# forced a value.
if [ "$VERSION_EXPLICIT" = "0" ]; then
  VERSION="$("$BUILD/spring" --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]{2}\.[0-9]{2}[^ ]*' | head -1)"
  [ -n "$VERSION" ] || { echo "FATAL: could not read engine version from $BUILD/spring --version"; exit 1; }
fi
echo "version: $VERSION (engine-reported; = fleet version identity)"
[ -n "$PORTVER" ] || { echo "FATAL: no port version (packaging/PORT_VERSION missing and no --port-version)"; exit 1; }
echo "port version: $PORTVER (user-facing release number)"

echo "=== [1b/7] streflop cross-arch sync-test (bit-exactness vs committed refs)"
if [ "$RUN_SYNC_TEST" = "1" ]; then
  ST_BUILD="$BUILD/synctest"
  cmake -S "$SRC/tools/sync-test" -B "$ST_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
  ninja -C "$ST_BUILD" >/dev/null
  "$ST_BUILD/streflop-float-test" "$ST_BUILD/st_" >/dev/null
  for ref in streflop_results_NEON_arm64.bin streflop_results_SSE_x86_64.bin; do
    python3 "$SRC/tools/sync-test/compare_results.py" \
        "$ST_BUILD"/st_*.bin "$SRC/tools/sync-test/reference/$ref" \
      | grep -q "RESULT: BIT-EXACT MATCH" \
      || { echo "FATAL: streflop sync-test diverged from $ref"; exit 1; }
  done
  echo "sync-test: BIT-EXACT vs both committed references"
else
  echo "(skipped by --skip-sync-test)"
fi

echo "=== [2/7] replay certification (opt-in; --certify / RELEASE_CERTIFY=1)"
if [ "$REPLAY_SMOKE" = "1" ]; then
  SMOKE_DEMO="${RELEASE_SMOKE_DEMO:-$(ls "$BAR"/refdemos/*_2025.06.24.sdfz 2>/dev/null | head -1)}"
  [ -n "$SMOKE_DEMO" ] || { echo "FATAL: --certify given but no smoke demo found (set RELEASE_SMOKE_DEMO)"; exit 1; }
  ENGINE_BUILD="$BUILD" "$BAR/scripts/replay-check.sh" "$SMOKE_DEMO" \
    || { echo "FATAL: replay certification failed"; exit 1; }
  CERTIFIED=1
else
  echo "(skipped — build/package tier; run 'make certify' or pass --certify to certify a shipping artifact)"
  CERTIFIED=0
fi

echo "=== [3/7] stage bundle"
rm -rf "$APP"
mkdir -p "$MACOS" "$FRAMEWORKS" "$RESOURCES"
cp "$BUILD/spring" "$MACOS/spring"
cp "$BUILD/tools/pr-downloader/src/pr-downloader" "$MACOS/pr-downloader" 2>/dev/null || \
  cp "$BUILD/tools/pr-downloader/src/pr-downloader_cli" "$MACOS/pr-downloader"
if [ "$PROFILE" = "engine" ]; then
  # engine consumers (game communities, dedicated hosts, replay tooling) get
  # the headless build too; the BAR helper app has no use for it
  cp "$BUILD/spring-headless" "$MACOS/spring-headless"
fi
if [ "$PROFILE" = "bar" ]; then
  # ---- BAR helper: launcher, content download/update, native helpers ----
  cp "$PKG/download-content.sh" "$RESOURCES/"
  cp "$PKG/launcher.sh" "$MACOS/launcher"
  chmod +x "$MACOS/launcher" "$RESOURCES/download-content.sh"
  # first-run consent + progress window + error dialog (native AppKit helpers)
  swiftc -O -o "$MACOS/progress-window" "$PKG/progress-window.swift" \
    || { echo "FATAL: progress-window.swift failed to compile"; exit 1; }
  swiftc -O -o "$MACOS/error-dialog" "$PKG/error-dialog.swift" \
    || { echo "FATAL: error-dialog.swift failed to compile"; exit 1; }
  swiftc -O -o "$MACOS/consent-dialog" "$PKG/consent-dialog.swift" \
    || { echo "FATAL: consent-dialog.swift failed to compile"; exit 1; }
fi
# base content archives (engine-built sdz)
mkdir -p "$RESOURCES/base"
find "$BUILD" -name "*.sdz" -exec cp {} "$RESOURCES/base/" \;
# base fonts: the engine loads fonts/FreeSansBold.otf as a LOOSE file from a
# datadir (not from an sdz) — without it the engine aborts at boot with
# "did you forget to run make install?". Ship the engine's cont/fonts.
cp -R "$SRC/cont/fonts" "$RESOURCES/fonts"
if [ "$PROFILE" = "bar" ]; then
  # BAR launcher config (chobby_config.json + default springsettings), extracted
  # from the canonical dist_cfg the official launcher uses; the launcher deploys
  # these at runtime (see launcher.sh). Without chobby_config.json the lobby
  # black-screens (game=generic -> Chobby shuts down).
  python3 "$PKG/extract-launcher-config.py" "$BAR/chobby/dist_cfg/config.json" "$RESOURCES" \
    || { echo "FATAL: could not extract BAR launcher config from dist_cfg"; exit 1; }
fi

# Mesa driver dylibs + ICD json (paths inside json rewritten to @loader_path-
# style relative locations at bundle time)
cp "$MESA_PREFIX"/lib/libEGL*.dylib "$FRAMEWORKS/" 2>/dev/null || true
cp "$MESA_PREFIX"/lib/libgallium*.dylib "$FRAMEWORKS/"
cp "$MESA_PREFIX"/lib/libvulkan_kosmickrisp.dylib "$FRAMEWORKS/"
# the Khronos Vulkan LOADER is a separate component (brew vulkan-loader) that
# zink dlopens at runtime — dev machines silently supplied it from
# /opt/homebrew/lib via env; user machines have nothing there (caught by the
# 6d GUI smoke: "ZINK: failed to load libvulkan.1.dylib")
cp -L /opt/homebrew/lib/libvulkan.1.dylib "$FRAMEWORKS/libvulkan.1.dylib"
# normalize install-name IDs of directly-staged driver dylibs (bundle_deps
# only re-IDs libraries it discovers as dependencies)
for d in "$FRAMEWORKS"/*.dylib; do
  chmod u+w "$d"
  install_name_tool -id "@rpath/$(basename "$d")" "$d" 2>/dev/null || true
done
mkdir -p "$RESOURCES/vulkan/icd.d"
sed 's|"library_path": ".*"|"library_path": "../../../Frameworks/libvulkan_kosmickrisp.dylib"|' \
  "$MESA_PREFIX/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json" \
  > "$RESOURCES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"

# Driver provenance: record exactly which Mesa commit + patches produced the
# bundled driver, so the shipped .app is traceable to reproducible source.
if [ -f "$MESA_PREFIX/.driver-provenance" ]; then
  cp "$MESA_PREFIX/.driver-provenance" "$RESOURCES/DRIVER-PROVENANCE.txt"
else
  echo "unverified (driver built out-of-band; rebuild with MESA_FORCE_REBUILD=1 to stamp)" \
    > "$RESOURCES/DRIVER-PROVENANCE.txt"
  echo "WARN: bundled driver has no provenance stamp — see DRIVER-PROVENANCE.txt"
fi

# Recursive dylib closure: copy every non-system dependency into Frameworks
# and rewrite install names to @rpath; binaries get a single LC_RPATH.
# NOTE: modern Homebrew dylibs reference same-package siblings as
# "@rpath/<name>" (e.g. libwebp -> @rpath/libsharpyuv.0.dylib) and rely on a
# cellar LC_RPATH we strip below — those siblings must be resolved via the
# SOURCE dylib's directory (then brew's lib dir) and copied too, or the
# bundle ships a dangling reference that dyld aborts on at user launch.
bundle_deps() { # bundle_deps <macho> [<source-dir-for-@rpath-siblings>]
  local m=$1 srcdir=${2:-} dep base deps cand rd
  # leaf dylibs legitimately have no non-system deps — grep "no match" must
  # not abort the pipeline under pipefail
  deps=$(otool -L "$m" | awk 'NR>1 {print $1}' | \
         grep -Ev '^(/System|/usr/lib|@loader_path|@executable_path)' || true)
  for dep in $deps; do
    base=$(basename "$dep")
    case "$dep" in
      @rpath/*)
        # already-bundled name: nothing to do. Otherwise resolve the sibling.
        if [ ! -f "$FRAMEWORKS/$base" ]; then
          cand=""
          for rd in "$srcdir" /opt/homebrew/lib; do
            [ -n "$rd" ] && [ -f "$rd/$base" ] && { cand="$rd/$base"; break; }
          done
          if [ -n "$cand" ]; then
            cp "$cand" "$FRAMEWORKS/$base"
            chmod u+w "$FRAMEWORKS/$base"
            install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base" 2>/dev/null
            bundle_deps "$FRAMEWORKS/$base" "$(dirname "$(readlink -f "$cand")")"
          fi
          # unresolvable @rpath refs are caught by the closure audit below
        fi
        ;;
      *)
        if [ ! -f "$FRAMEWORKS/$base" ]; then
          cp "$dep" "$FRAMEWORKS/$base"
          chmod u+w "$FRAMEWORKS/$base"
          install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base" 2>/dev/null
          bundle_deps "$FRAMEWORKS/$base" "$(dirname "$(readlink -f "$dep")")"
        fi
        install_name_tool -change "$dep" "@rpath/$base" "$m" 2>/dev/null
        ;;
    esac
  done
}
for b in "$MACOS/spring" "$MACOS/spring-headless" "$MACOS/pr-downloader"; do
  [ -f "$b" ] || continue
  bundle_deps "$b"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$b" 2>/dev/null || true
done
for d in "$FRAMEWORKS"/*.dylib; do bundle_deps "$d"; done

# Build machines leak LC_RPATHs into binaries (brew lib dirs, build trees).
# Inside the bundle those must not exist: a foreign rpath makes dyld resolve
# @rpath deps OUTSIDE the bundle (works on the build box, breaks or loads the
# WRONG library on user machines — caught by the 6d GUI smoke). Strip every
# rpath that is not bundle-relative, give dylibs a @loader_path fallback,
# then hard-audit: no absolute non-system references may remain anywhere.
strip_foreign_rpaths() { # strip_foreign_rpaths <macho>
  local m=$1 rp
  otool -l "$m" | awk '/LC_RPATH/{getline;getline; print $2}' | while read -r rp; do
    case "$rp" in
      @executable_path/*|@loader_path/*) ;;
      *) install_name_tool -delete_rpath "$rp" "$m" 2>/dev/null || true ;;
    esac
  done
}
for m in "$MACOS/spring" "$MACOS/pr-downloader" "$FRAMEWORKS"/*.dylib; do
  strip_foreign_rpaths "$m"
done
for d in "$FRAMEWORKS"/*.dylib; do
  install_name_tool -add_rpath "@loader_path" "$d" 2>/dev/null || true
done
AUDIT_FAIL=0
for m in "$MACOS/spring" "$MACOS/pr-downloader" "$FRAMEWORKS"/*.dylib; do
  # dylibs print their own LC_ID_DYLIB as line 2 — skip it (IDs are
  # normalized to @rpath above; only real DEPENDENCIES matter here)
  skip=2; case "$m" in *.dylib) skip=3;; esac
  bad=$(otool -L "$m" | tail -n +$skip | awk '{print $1}' | \
        grep -Ev '^(/System|/usr/lib|@rpath|@loader_path|@executable_path)' || true)
  if [ -n "$bad" ]; then
    echo "FATAL: $m still references non-bundled libraries:"; echo "$bad"
    AUDIT_FAIL=1
  fi
  # @rpath references must RESOLVE inside the bundle — a name that no copied
  # dylib satisfies is a dyld abort on the user's machine, not the build box
  # (brew sibling refs, e.g. libwebp -> @rpath/libsharpyuv.0.dylib)
  for ref in $(otool -L "$m" | tail -n +$skip | awk '{print $1}' | grep '^@rpath/' || true); do
    rbase=${ref#@rpath/}
    if [ ! -f "$FRAMEWORKS/$rbase" ] && [ ! -f "$(dirname "$m")/$rbase" ]; then
      echo "FATAL: $m references $ref but $rbase is not in the bundle"
      AUDIT_FAIL=1
    fi
  done
done
[ "$AUDIT_FAIL" = "0" ] || exit 1
echo "bundle closure audit: all references bundle-relative, resolvable, or system"

# Info.plist — version string clearly identifies the mac port build
# (SYNC_VALIDATION.md §6: server-side triage must be trivial).
# Profile decides identity: the BAR helper app presents as the game client
# (launcher entrypoint, BAR icon); the engine bundle is neutral Recoil (spring
# entrypoint, no game branding, engine version user-facing).
if [ "$PROFILE" = "bar" ]; then
  PLIST_ID="dev.bar-macos.bar-launcher"
  PLIST_NAME="BAR Launcher"
  PLIST_EXEC="launcher"
  PLIST_SHORTVER="$PORTVER"
  PLIST_ICON_KEYS='<key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>'
  PLIST_LAN_NAME="BAR Launcher (and the game it launches)"
else
  PLIST_ID="dev.bar-macos.recoil-engine"
  PLIST_NAME="Recoil Engine"
  PLIST_EXEC="spring"
  PLIST_SHORTVER="$VERSION"
  PLIST_ICON_KEYS=""
  PLIST_LAN_NAME="The Recoil engine"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${PLIST_ID}</string>
  <key>CFBundleName</key><string>${PLIST_NAME}</string>
  <key>CFBundleDisplayName</key><string>${PLIST_NAME}</string>
  <key>CFBundleExecutable</key><string>${PLIST_EXEC}</string>
  ${PLIST_ICON_KEYS}
  <!-- user-facing version; engine pin stays queryable for triage -->
  <key>CFBundleShortVersionString</key><string>${PLIST_SHORTVER}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>EngineVersion</key><string>${VERSION}</string>
  <key>PortVersion</key><string>${PORTVER}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.strategy-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <!-- macOS 15+ Local Network prompt text (LAN hosting/joining only;
       internet servers are unaffected) -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>${PLIST_LAN_NAME} uses the local network to host and join LAN multiplayer games.</string>
</dict></plist>
PLIST

if [ "$PROFILE" = "bar" ]; then
  # App icon. Assets.car is the native macOS 26 icon (CFBundleIconName) — the
  # system renders it full-tile with its own glass; a legacy .icns alone gets
  # shrunk onto a white tray on Tahoe. AppIcon.icns is the actool-generated
  # fallback (CFBundleIconFile). Both are compiled from packaging/AppIcon.icon
  # by packaging/build-icon.sh and committed. Staged before codesign so they
  # are sealed by the bundle signature. (BAR helper only — the engine bundle
  # stays unbranded.)
  mkdir -p "$RESOURCES"
  cp "$PKG/Assets.car" "$RESOURCES/Assets.car"
  cp "$PKG/AppIcon.icns" "$RESOURCES/AppIcon.icns"
  echo "app icon staged: Assets.car + AppIcon.icns"

  # Spotlight keywords: the app is named "BAR Launcher" (it is not the game),
  # but users will search for the game's name — kMDItemKeywords lets Spotlight
  # (and Raycast/Alfred) match "Beyond All Reason" without the app claiming
  # that name. Stored as an xattr (binary plist array); xattrs are outside the
  # codesign seal and survive ditto zips and DMGs.
  KEYWORDS_HEX=$(python3 -c "import plistlib; print(plistlib.dumps(['Beyond All Reason','BAR','RTS','Recoil'],fmt=plistlib.FMT_BINARY).hex())")
  xattr -wx com.apple.metadata:kMDItemKeywords "$KEYWORDS_HEX" "$APP"
  echo "spotlight keywords staged"
fi

echo "=== [4/7] license collection + audit"
mkdir -p "$RESOURCES/LICENSES"
cp "$SRC/COPYING" "$RESOURCES/"
cp "$PKG/NOTICE" "$RESOURCES/"
cp "$PKG/LICENSES/MANIFEST.tsv" "$RESOURCES/LICENSES/"
"$PKG/collect-licenses.sh" "$RESOURCES/LICENSES" || { echo "FATAL: license collection failed"; exit 1; }
cp "$RESOURCES/LICENSES/"*.txt "$PKG/LICENSES/" 2>/dev/null || true
"$PKG/license-audit.sh" "$APP"

echo "=== [5/7] codesign (hardened runtime)"
ENTITLEMENTS="$PKG/entitlements.plist"
# Ad-hoc signatures carry no Team ID, so hardened-runtime library validation
# rejects every bundled dylib ("different Team IDs") and the GUI smoke can
# never pass. Local ad-hoc builds therefore sign with library validation
# DISABLED; identity builds keep the strict entitlements (same-team dylibs
# validate fine). Ship artifacts are always identity-signed.
if [ "$IDENTITY" = "-" ]; then
  ENTITLEMENTS=$(mktemp -t entitlements-adhoc).plist
  sed 's|<key>com.apple.security.cs.disable-library-validation</key><false/>|<key>com.apple.security.cs.disable-library-validation</key><true/>|' \
    "$PKG/entitlements.plist" > "$ENTITLEMENTS"
  echo "(ad-hoc: library validation disabled for local smoke — NOT a ship config)"
fi
# every dylib first, then nested executables, then the bundle
find "$APP" -name "*.dylib" -exec codesign --force --options runtime --timestamp ${IDENTITY:+-s "$IDENTITY"} {} \;
for b in "$MACOS"/*; do
  # only Mach-O executables; scripts are sealed by the app-level signature
  [ -f "$b" ] && file -b "$b" | grep -q "Mach-O" && \
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$b"
done
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"

# HARD GATE: a release artifact must never carry get-task-allow
if codesign -d --entitlements - --xml "$APP/Contents/MacOS/spring" 2>/dev/null | grep -q "get-task-allow"; then
  echo "FATAL: get-task-allow present in release artifact (sign-for-profiling leaked in?)"
  exit 1
fi
codesign --verify --deep --strict "$APP"
echo "codesign OK (identity: ${IDENTITY})"

echo "=== [6/7] notarization"
mkdir -p "$OUT"
if [ "$PROFILE" = "bar" ]; then
  ZIP="$OUT/BAR-macos-${PORTVER}.zip"
else
  ZIP="$OUT/Recoil-macos-${VERSION}-port${PORTVER}.zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ "$IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  # re-zip with the stapled ticket
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
else
  echo "(skipped: ad-hoc signature or no --notary-profile; Gatekeeper will"
  echo " reject this artifact on other machines — for local testing only)"
fi

echo "=== [6c/7] DMG (styled drag-to-Applications)"
if [ "$PROFILE" != "bar" ]; then
  DMG="(none — engine profile ships the notarized zip only)"
  echo "(skipped — the engine bundle is consumed by tooling/other launchers, not drag-installed)"
else
DMG="$OUT/BAR-macos-${PORTVER}.dmg"
VOLNAME="BAR Launcher"
rm -f "$DMG"
DMGROOT=$(mktemp -d)
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
mkdir "$DMGROOT/.background"
cp "$PKG/dmg-background.png" "$DMGROOT/.background/background.png"
cp "$PKG/AppIcon.icns" "$DMGROOT/.VolumeIcon.icns"

# read-write image first so Finder can lay it out (positions/background live
# in the volume's .DS_Store), then compress to the shipping UDZO
RWDMG="$OUT/.rw-$$.dmg"
rm -f "$RWDMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$DMGROOT" -fs HFS+ \
  -format UDRW -ov "$RWDMG" >/dev/null
rm -rf "$DMGROOT"
MOUNTPT="/Volumes/$VOLNAME"
hdiutil detach "$MOUNTPT" >/dev/null 2>&1 || true
hdiutil attach "$RWDMG" -mountpoint "$MOUNTPT" -nobrowse >/dev/null
SetFile -a C "$MOUNTPT" 2>/dev/null || true   # honor .VolumeIcon.icns
# Write the styling .DS_Store (icon view, background picture, icon positions
# on the arrow endpoints) directly — headless, no Finder/Automation needed.
python3 "$PKG/dmg-layout.py" "$MOUNTPT" "$(basename "$APP")" \
  || { echo "FATAL: dmg layout failed"; hdiutil detach "$MOUNTPT" >/dev/null; exit 1; }
sync
hdiutil detach "$MOUNTPT" >/dev/null
hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RWDMG"
if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp -s "$IDENTITY" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
echo "dmg: $DMG"
fi   # PROFILE=bar

echo "=== [6d/7] signed-bundle GUI driver-identity smoke (opt-in; needs a GPU)"
# Requires a real Apple Silicon GPU/display, so it lives in the certify tier
# (a headless build box cannot run it). When certifying: the DYLD-stripping
# behavior of the hardened runtime CANNOT be exercised by headless or ad-hoc
# runs alone — launch the actual bundle launcher briefly and require the
# KosmicKrisp identity line (golden rule 11); a silent llvmpipe fallback in the
# SIGNED bundle must fail the build, never ship.
if [ "$REPLAY_SMOKE" = "1" ] && [ "$PROFILE" != "bar" ]; then
  echo "(engine profile has no launcher; the GUI smoke runs in the bar profile"
  echo " — the engine binaries and dylib closure are identical between the two)"
elif [ "$REPLAY_SMOKE" = "1" ]; then
  SMOKELOG=$(mktemp)
  SMOKEDIR=$(mktemp -d)
  mkdir -p "$SMOKEDIR/rapid"   # skip the first-run lobby download
  BAR_WRITEDIR_OVERRIDE="$SMOKEDIR" BAR_CONTENT_SCOPE=lobby BAR_ASSUME_CONSENT=1 \
    timeout 90 "$APP/Contents/MacOS/launcher" \
    > "$SMOKELOG" 2>&1 || true
  if grep -q "KOSMICKRISP_LOADED" "$SMOKELOG" "$SMOKEDIR/infolog.txt" 2>/dev/null; then
    echo "bundle GUI smoke: KosmicKrisp identity verified"
  else
    echo "FATAL: signed bundle did not load KosmicKrisp (DYLD/rpath regression?)"
    tail -20 "$SMOKELOG"; exit 1
  fi
  rm -rf "$SMOKEDIR" "$SMOKELOG"
else
  echo "(skipped — certify tier; needs a GPU. Run 'make certify' on an Apple Silicon Mac)"
fi


echo "=== [7/7] summary"
echo "profile:   $PROFILE"
echo "artifact:  $APP"
echo "bundles:   $ZIP"
echo "           $DMG"
echo "signing:   $([ "$IDENTITY" = "-" ] && echo "ad-hoc (local only)" || echo "Developer ID${NOTARY_PROFILE:+ + notarized}")"
echo "certified: $([ "$CERTIFIED" = "1" ] && echo "yes (replay determinism + GPU driver smoke)" || echo "NO (build/package tier only)")"
if [ "$IDENTITY" != "-" ] && [ "$CERTIFIED" != "1" ]; then
  echo ""
  echo "!!  WARNING: this is a SIGNED (shipping-shaped) bundle that was NOT"
  echo "!!  certified. A lockstep-multiplayer client must pass replay-determinism"
  echo "!!  certification before it reaches players. Run 'make certify' (or re-run"
  echo "!!  with --certify) on an Apple Silicon Mac before distributing."
elif [ "$CERTIFIED" != "1" ]; then
  echo "REMINDER: full certification (graphics soak + full-length REPLAY_SYNC_OK)"
  echo "must pass before this artifact is uploaded anywhere (plan §10) — 'make certify'."
fi
