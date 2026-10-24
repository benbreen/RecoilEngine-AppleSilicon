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
# The shipped pair lives in ONE place, shared with scripts/visreg.sh so the
# release gate and an interactive visreg run cannot drift apart. Bump it there.
. "$PKG/ship-config.sh"
BUILD_HINT="${ENGINE_BUILD:-$SHIP_ENGINE_BUILD}"
# Source tree: FOLLOW THE BUILD DIR we are told to package, do not name a tree.
# This was hardcoded to $BAR/engine-2025.06.24, which stopped being the shipping
# tree on 2026-08-07 when the 2026.07.04 lane was consolidated into engine/. With
# ship-config pointing BUILD at build-engine-2026.07.04, a bare release build
# would have reconfigured that dir onto the OLD source and packaged 2025.06.24
# code as v0.13. build-engine.sh's source-tree guard refused it (LESSON-59) —
# this is the fifth script found pinning a path instead of following its input,
# and the first where the consequence would have been a mislabelled RELEASE.
if [ -z "${ENGINE_SRC:-}" ] && [ -f "$BUILD_HINT/CMakeCache.txt" ]; then
  ENGINE_SRC=$(awk -F= '/^CMAKE_HOME_DIRECTORY:INTERNAL=/{print $2}' "$BUILD_HINT/CMakeCache.txt")
fi
SRC="${ENGINE_SRC:-$([ -d "$BAR/rts" ] && echo "$BAR" || echo "$BAR/engine")}"
BUILD="${ENGINE_BUILD:-$SHIP_ENGINE_BUILD}"
OUT="${RELEASE_OUT:-$BAR/release-artifacts}"
# release driver prefix: built from the mesa bar-macos branch (never the
# experiments driver the dev/play stack uses)
MESA_PREFIX="${MESA_PREFIX:-$SHIP_MESA_PREFIX}"
IDENTITY="-"           # "-" = ad-hoc
NOTARY_PROFILE=""
# App Store Connect API-key auth (alternative to the keychain profile, and
# more durable — reads the .p8 from disk each run, so it survives whatever
# clears keychain items). Set all three (flags or env) to use it; it takes
# precedence over --notary-profile.
NOTARY_KEY="${NOTARY_KEY:-}"          # path to AuthKey_XXXX.p8
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"    # the key's Key ID
NOTARY_ISSUER="${NOTARY_ISSUER:-}"    # the issuer UUID
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
# Online play (bar profile): **DISABLED by default, and that is a standing rule,
# not a per-release choice** (user decision, 2026-08-08). Every release so far has
# been respun with --disable-online before shipping — v0.11 and v0.12 both were —
# so the default was a trap: it made the safe outcome depend on someone
# remembering a flag, and forgetting it publishes a build that reaches BAR's real
# lobby servers. The default now matches the rule.
#
# Disabled means the staged chobby_config.json points the lobby at an unreachable
# loopback endpoint and the launcher shows a once-per-version notice. Engine-level
# networking (direct/LAN) is untouched either way.
#
# --enable-online (or BAR_ONLINE=1) is a DELIBERATE opt-in and must not be used
# for a public artifact without an explicit decision to seek approval from BAR's
# maintainers first; see docs/OUTSTANDING.md on the online-play posture.
ENABLE_ONLINE="${BAR_ONLINE:-0}"
# Message config source (bar profile): where the shipped launcher fetches
# messages.json each launch. Default = the port's GitHub repo. Override with
# --messages-config <https-url> or --messages-local <path> (a local file,
# baked as a file:// URL — for testing builds against an unpublished config).
MESSAGES_CONFIG="${BAR_MESSAGES_CONFIG:-https://raw.githubusercontent.com/benbreen/RecoilEngine-AppleSilicon/main/message-config/messages.json}"

# Test tiers (mirrors upstream Recoil CI: the *build* workflow only builds +
# packages; ALL test stages are OPT-IN as of 2026-07-20 — plain builds stay
# fast, big changes / release candidates run the tests, either with the build
# or standalone):
#   - --with-synctest  streflop bit-exactness (CPU-only, seconds).
#                      standalone: scripts/run-synctest.sh
#   - --with-visreg    visual/artifact regression vs baselines (~3 min).
#                      standalone: scripts/visreg.sh
#   - --with-perf      adds the m7 perf gate to visreg (~+4 min).
#                      standalone: scripts/visreg.sh --perf
#   - --certify        replay smoke (headless full-game re-sim; tens of
#                      minutes; needs game content). CERTIFICATION, not a
#                      build gate.
# A SHIPPING artifact must have passed sync-test + visreg(+perf) + certify —
# skipped stages warn loudly below but do not hard-fail, so build boxes can
# package; run the missing stages standalone before publishing.
RUN_SYNC_TEST=${RELEASE_SYNC_TEST:-0}
RUN_VISREG=${RELEASE_VISREG:-0}
RUN_VISREG_PERF=0
REPLAY_SMOKE=${RELEASE_CERTIFY:-0}

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY=$2; shift 2;;
    --notary-profile) NOTARY_PROFILE=$2; shift 2;;
    --notary-key) NOTARY_KEY=$2; shift 2;;
    --notary-key-id) NOTARY_KEY_ID=$2; shift 2;;
    --notary-issuer) NOTARY_ISSUER=$2; shift 2;;
    --version) VERSION=$2; VERSION_EXPLICIT=1; shift 2;;
    --port-version) PORTVER=$2; shift 2;;
    --profile) PROFILE=$2; shift 2;;
    --enable-online) ENABLE_ONLINE=1; shift;;   # DELIBERATE opt-in; never for a public artifact
    --disable-online) ENABLE_ONLINE=0; shift;;  # now the default; kept for explicitness
    --messages-config) MESSAGES_CONFIG=$2; shift 2;;
    --messages-local)
      [ -f "$2" ] || { echo "FATAL: --messages-local $2: no such file"; exit 2; }
      MESSAGES_CONFIG="file://$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2;;
    --certify|--replay-smoke) REPLAY_SMOKE=1; shift;;
    --skip-replay-smoke) REPLAY_SMOKE=0; shift;;   # now the default; kept for compat
    --with-synctest) RUN_SYNC_TEST=1; shift;;
    --skip-sync-test) RUN_SYNC_TEST=0; shift;;     # now the default; kept for compat
    --with-visreg) RUN_VISREG=1; shift;;
    --with-perf) RUN_VISREG=1; RUN_VISREG_PERF=1; shift;;
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

# Pre-flight: if this run will notarize, make sure the keychain profile
# actually resolves NOW — a missing/expired credential otherwise wastes the
# whole ~10-min build only to die at the notarize step (keychain items don't
# always survive a relogin/keychain relock).
# Resolve notarization auth once: API key (durable) takes precedence over the
# keychain profile. NOTARY_AUTH is the arg list passed to every notarytool call.
NOTARY_AUTH=()
if [ -n "$NOTARY_KEY" ] && [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER" ]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  NOTARY_DESC="API key $NOTARY_KEY_ID"
elif [ -n "$NOTARY_PROFILE" ]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  NOTARY_DESC="keychain profile '$NOTARY_PROFILE'"
fi
if [ "$IDENTITY" != "-" ] && [ "${#NOTARY_AUTH[@]}" -gt 0 ]; then
  xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || {
    echo "FATAL: notarization auth ($NOTARY_DESC) does not resolve. Re-store the"
    echo "keychain profile, or pass an API key (--notary-key/-key-id/-issuer or"
    echo "NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER) which does not depend on the keychain."
    exit 1
  }
  echo "notarization auth: $NOTARY_DESC — OK"
fi

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
  ENGINE_SRC="$SRC" "$BAR/scripts/run-synctest.sh" --build-dir "$BUILD/synctest"
else
  echo "WARNING: sync-test SKIPPED (opt-in as of 2026-07-20)."
  echo "         A shipping artifact must have passed it — run with"
  echo "         --with-synctest or standalone: scripts/run-synctest.sh"
fi

echo "=== [1c/7] visreg (visual/artifact/perf regression)"
if [ "$RUN_VISREG" = "1" ]; then
  VR_ARGS=()
  [ "$RUN_VISREG_PERF" = "1" ] && VR_ARGS+=(--perf)
  VISREG_BUILD="$BUILD" VISREG_MESA="$MESA_PREFIX" \
    "$BAR/scripts/visreg.sh" ${VR_ARGS[@]+"${VR_ARGS[@]}"} \
    || { echo "FATAL: visreg regression gate failed"; exit 1; }
else
  echo "WARNING: visreg SKIPPED (opt-in). Before shipping run with"
  echo "         --with-visreg [--with-perf] or standalone: scripts/visreg.sh --perf"
fi

echo "=== [2/7] replay certification (opt-in; --certify / RELEASE_CERTIFY=1)"
if [ "$REPLAY_SMOKE" = "1" ]; then
  # FOLLOW THE ENGINE WE ARE PACKAGING, do not name a lane. This glob was pinned
  # to *_2025.06.24.sdfz, so on the 2026.07.04 lane `make certify` picked a demo
  # recorded by the OLD engine and replay-check.sh correctly refused it
  # ("VERSION_MISMATCH: demo=2025.06.24 binary=2026.07.04"), taking the whole
  # release build down with it — while refdemos/2026.07.04/ sat there full of
  # demos recorded on this very lane. Same defect as the five other pinned paths
  # called out at the top of this file, and as mp-test.sh's 2025 defaults.
  # $VERSION is the engine-reported version resolved in step 1 above.
  SMOKE_DEMO="${RELEASE_SMOKE_DEMO:-}"
  if [ -z "$SMOKE_DEMO" ]; then
    # per-lane directory first (current layout), then the flat legacy naming
    SMOKE_DEMO=$(ls "$BAR/refdemos/$VERSION"/*.sdfz 2>/dev/null | sort | head -1)
    [ -n "$SMOKE_DEMO" ] || SMOKE_DEMO=$(ls "$BAR"/refdemos/*_"$VERSION".sdfz 2>/dev/null | sort | head -1)
  fi
  [ -n "$SMOKE_DEMO" ] || {
    echo "FATAL: --certify given but no smoke demo recorded on engine $VERSION."
    echo "       Searched: refdemos/$VERSION/*.sdfz and refdemos/*_$VERSION.sdfz"
    echo "       A demo from another engine version CANNOT certify this one --"
    echo "       replay-check.sh refuses it as VERSION_MISMATCH. Record a demo on"
    echo "       this lane, or point RELEASE_SMOKE_DEMO at one."
    exit 1; }
  echo "smoke demo: $(basename "$SMOKE_DEMO") (engine $VERSION)"
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
  swiftc -O -o "$MACOS/message-check" "$PKG/message-check.swift" \
    || { echo "FATAL: message-check.swift failed to compile"; exit 1; }
fi
# base content archives (engine-built sdz)
mkdir -p "$RESOURCES/base"
find "$BUILD" -name "*.sdz" -exec cp {} "$RESOURCES/base/" \;
# native skirmish AIs (issue #1): runtime AI/ tree assembled by
# build-engine.sh (C interface + BARb + NullAI). Lives in Resources = the
# engine's read-only datadir, so FetchSkirmishAILibrary finds it.
[ -d "$BUILD/AI" ] || { echo "FATAL: no AI/ runtime tree in $BUILD (AI_TYPES=NONE build?)"; exit 1; }
cp -R "$BUILD/AI" "$RESOURCES/AI"
# Drop the CMake build cruft that cp -R drags in (CMakeFiles/, cmake_install.cmake,
# Makefile, *.o). The engine never loads it at runtime — it scans the tree for
# AIInfo.lua + the AI dylib — and it embeds the absolute build path (a
# leak, e.g. cmake_install.cmake's "Install script for directory: <path>").
find "$RESOURCES/AI" -name CMakeFiles -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$RESOURCES/AI" -type f \( -name '*.cmake' -o -name 'Makefile' -o -name 'CMakeCache.txt' -o -name '*.o' \) -delete 2>/dev/null || true
for ai in "AI/Interfaces/C/0.1/libAIInterface.dylib" "AI/Skirmish/BARb/stable/libSkirmishAI.dylib" "AI/Skirmish/NullAI/0.1/libSkirmishAI.dylib"; do
  test -f "$RESOURCES/$ai" || { echo "FATAL: $ai missing from staged AI tree"; exit 1; }
  file "$RESOURCES/$ai" | grep -q arm64 || { echo "FATAL: $ai not arm64"; exit 1; }
done
# base fonts: the engine loads fonts/FreeSansBold.otf as a LOOSE file from a
# datadir (not from an sdz) — without it the engine aborts at boot with
# "did you forget to run make install?". Ship the engine's cont/fonts.
cp -R "$SRC/cont/fonts" "$RESOURCES/fonts"
# cont/LuaUI/ctrlpanel.txt: BAR's own LuaUI asks the engine for this file by name
# at boot (game/luaui/main.lua: SendCommands "ctrlpanel LuaUI/ctrlpanel.txt"), and
# it is NOT inside any sdz — the engine can only find it as a LOOSE file on a
# datadir, exactly like cont/fonts above. It sets `frameAlpha 0.0`, which is what
# suppresses the engine's built-in command panel; BAR draws its own.
# When it is missing, CGuiHandler::ReloadConfigFromFile reads an empty string and
# LoadConfig() silently leaves the compiled-in defaults standing (frameAlpha -1 ->
# guiAlpha 0.8), so the engine paints a flat grey 0.2/0.2/0.2 quad in the lower
# left the moment anything is selected — visible to players in the gap between
# BAR's minimap and its grid build menu. Every release up to and including the
# v0.13 RC shipped without it; official Windows/Linux installs ship it loose,
# which is why the box is macOS-only. See DEVLOG 2026-08-08.
# Only this one file, NOT all of cont/LuaUI: with devmode on, LuaUI.cpp loads at
# SPRING_VFS_RAW_FIRST, so a loose main.lua would shadow BAR's own UI.
mkdir -p "$RESOURCES/LuaUI"
cp "$SRC/cont/LuaUI/ctrlpanel.txt" "$RESOURCES/LuaUI/ctrlpanel.txt"
# cmdcolors.txt is the SAME class and the only other file in it (2026-08-08 audit
# of every loose file in the official Windows/Linux archives). Game.cpp:771 reads
# it raw-FS-first and unconditionally; missing, LoadConfigFromString("") is a
# no-op and the engine's compiled-in defaults stand — solid command lines instead
# of dashed, different alphas — with no error surfaced, exactly like ctrlpanel.
# BAR's Cursor widget normally re-specifies all 57 keys from
# cmdcolors_icexuick.txt, so this is belt-and-braces rather than a live bug: it
# only shows for the first few frames, and for a player who disables that widget.
# 3 KB, cannot shadow anything, and it restores exact parity with Windows/Linux.
cp "$SRC/cont/cmdcolors.txt" "$RESOURCES/cmdcolors.txt"
test -s "$RESOURCES/LuaUI/ctrlpanel.txt" || { echo "FATAL: cont/LuaUI/ctrlpanel.txt missing from $SRC"; exit 1; }
test -s "$RESOURCES/cmdcolors.txt" || { echo "FATAL: cont/cmdcolors.txt missing from $SRC"; exit 1; }
if [ "$PROFILE" = "bar" ]; then
  # BAR launcher config (chobby_config.json + default springsettings), extracted
  # from the canonical dist_cfg the official launcher uses; the launcher deploys
  # these at runtime (see launcher.sh). Without chobby_config.json the lobby
  # black-screens (game=generic -> Chobby shuts down).
  # A local BYAR-Chobby checkout at $BAR/chobby wins; otherwise fetch the one
  # file from the commit pinned in ship-config.sh (a fresh clone has no chobby/).
  DIST_CFG="$BAR/chobby/dist_cfg/config.json"
  if [ ! -f "$DIST_CFG" ]; then
    DIST_CFG="$BAR/deps/chobby-dist_cfg-$SHIP_CHOBBY_COMMIT.json"
    if [ ! -s "$DIST_CFG" ]; then
      mkdir -p "$BAR/deps"
      curl -fsSL --retry 3 -o "$DIST_CFG.tmp" \
        "https://raw.githubusercontent.com/beyond-all-reason/BYAR-Chobby/$SHIP_CHOBBY_COMMIT/dist_cfg/config.json" \
        && mv "$DIST_CFG.tmp" "$DIST_CFG" \
        || { rm -f "$DIST_CFG.tmp"; echo "FATAL: could not fetch BYAR-Chobby dist_cfg @ $SHIP_CHOBBY_COMMIT"; exit 1; }
    fi
    echo "dist_cfg: BYAR-Chobby @ $SHIP_CHOBBY_COMMIT"
  fi
  python3 "$PKG/extract-launcher-config.py" "$DIST_CFG" "$RESOURCES" \
    || { echo "FATAL: could not extract BAR launcher config from dist_cfg"; exit 1; }
  # BAR_CONTENT_TAGS: DIAGNOSTIC ONLY. Overrides the rapid tags the bundle
  # downloads (normally byar:test + byar-chobby:test, i.e. exactly what the
  # official launcher installs). Its only sanctioned use is bisecting a BAR
  # CONTENT regression by pinning `byar:git:<sha>` -- e.g. proving that the
  # 2026-08-04 HUD breakage arrived with content 30868 and is absent on 30711.
  # NEVER ship a build made with this: it puts players on non-standard content,
  # which is unwelcome to BAR maintainers and wrong for online play (user
  # decision 2026-08-04). Hence the shouty banner and the marker file.
  if [ -n "${BAR_CONTENT_TAGS:-}" ]; then
    printf '%s\n' "$BAR_CONTENT_TAGS" > "$RESOURCES/content_tags"
    printf 'DIAGNOSTIC BUILD - content pinned to:\n%s\nNOT FOR DISTRIBUTION.\n' \
      "$BAR_CONTENT_TAGS" > "$RESOURCES/PINNED-CONTENT-DO-NOT-SHIP.txt"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!  DIAGNOSTIC BUILD: content tags OVERRIDDEN"
    printf '!!  %s\n' $BAR_CONTENT_TAGS
    echo "!!  This bundle installs NON-STANDARD game content."
    echo "!!  Do NOT distribute it. Do NOT use it for online play."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  fi
  if [ "$ENABLE_ONLINE" != "1" ]; then
    # Neuter the lobby-server endpoint so online play cannot connect:
    #   host: online-play-disabled.localhost — .localhost is a reserved TLD
    #     (RFC 6761) that resolvers MUST map to loopback, so a connection can
    #     never leave the machine (no ISP NXDOMAIN-hijack risk) and the name
    #     can never be registered. Descriptive too — the lobby prints it.
    #   port: 1 (tcpmux) — a privileged port nothing on a normal Mac listens
    #     on, so the loopback connect is refused INSTANTLY (no hang, no chance
    #     of hitting a local dev server that might sit on a common port).
    # The marker file makes the launcher show the "online play disabled" notice.
    python3 - "$RESOURCES/chobby_config.json" <<'NEUTER'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg.setdefault("server", {})["address"] = "online-play-disabled.localhost"
cfg["server"]["port"] = 1
json.dump(cfg, open(p, "w"), indent=2)
NEUTER
    touch "$RESOURCES/.online-play-disabled"
    echo "online play: DISABLED (--disable-online / BAR_ONLINE=0)"
  else
    echo "online play: ENABLED (default)"
  fi
  # Bake the message-config source for the shipped launcher (launcher.sh reads
  # this staged file; BAR_MESSAGE_CONFIG_URL still overrides at runtime).
  printf '%s' "$MESSAGES_CONFIG" > "$RESOURCES/.message-config-url"
  echo "message config: $MESSAGES_CONFIG"
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

# Strip debug symbol tables from every bundled Mach-O. A RELWITHDEBINFO link
# records one OSO debug-map entry per object file, each holding the ABSOLUTE
# path of the .o/.a it came from — 875 of them in `spring` alone, i.e. the
# builder's home directory, inside a notarized artifact. v0.12 shipped exactly
# that. `strings` does NOT reveal them (it reads only __TEXT), which is why the
# LESSON-41 scan, which caught Mesa's drirc strings, missed this whole class.
# -S drops the debug (STABS) entries only and keeps the regular symbol table,
# so crash backtraces still resolve function names. Must run before codesign:
# stripping a signed Mach-O invalidates its signature.
while IFS= read -r m; do
  case "$(file -b "$m" 2>/dev/null)" in *Mach-O*) ;; *) continue;; esac
  chmod u+w "$m" 2>/dev/null || true
  strip -S "$m" 2>/dev/null || true
done <<EOF
$(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
EOF
echo "debug symbol tables stripped from bundled Mach-Os"

# Builder-path audit. Scan the ARTIFACT and hard-fail: whatever reaches
# this point is about to be signed, notarized and published, and publishing
# cannot be undone. Uses a raw byte grep, NOT `strings` — `strings` reads only
# the text section by default and silently misses debug-map paths (LESSON-41).
PATHLEAK_FAIL=0
while IFS= read -r m; do
  # LC_ALL=C on sort too, or a UTF-8 locale makes it abort on raw bytes
  # ("Illegal byte sequence") and the audit silently passes
  hits="$(LC_ALL=C grep -a -o '/Users/[^ "]\{0,120\}' "$m" 2>/dev/null | LC_ALL=C sort -u || true)"
  if [ -n "$hits" ]; then
    echo "FATAL: ${m#"$APP"/} embeds $(echo "$hits" | wc -l | tr -d ' ') builder path(s):"
    echo "$hits" | head -5 | sed 's/^/    /'
    PATHLEAK_FAIL=1
  fi
done <<EOF
$(find "$APP" -type f 2>/dev/null)
EOF
[ "$PATHLEAK_FAIL" = "0" ] || { echo "FATAL: refusing to package an artifact containing builder paths — see LESSON-41"; exit 1; }
echo "builder-path audit: no /Users/ paths anywhere in the bundle"

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

# ---- loose-file manifest gate -------------------------------------------------
# Some files the engine needs resolve ONLY from the raw filesystem on a datadir,
# never from an .sdz, and the launcher gives the bundle exactly ONE read-only
# datadir: Resources. We hand-pick what to copy out of the engine's cont/ tree,
# so "forgot to copy it" is a permanent, silent failure mode -- cont/LuaUI/
# ctrlpanel.txt was missing for v0.11, v0.12 and the v0.13 RC and nothing caught
# it, because the file's absence is indistinguishable from an empty file to the
# engine (it logs "Reloading GUI config from file: ..." either way).
#
# So state the required set ONCE, here, and assert it. A `cp` accidentally
# dropped upstream of this now fails the build instead of shipping.
# Adding a file to this list is the ONLY correct way to change what we require.
echo "=== [3z/7] loose-file manifest (files the engine can only read raw)"
REQUIRED_LOOSE=(
  "fonts/FreeSansBold.otf"      # engine aborts at boot without it
  "LuaUI/ctrlpanel.txt"         # frameAlpha 0.0 -> suppresses the engine's own command panel
  "cmdcolors.txt"               # command-line colours/stipple; same silent-default failure mode
)
_loose_missing=0
for rel in "${REQUIRED_LOOSE[@]}"; do
  if [ -s "$RESOURCES/$rel" ]; then
    echo "  ok      $rel"
  else
    echo "  MISSING $rel"
    _loose_missing=1
  fi
done
[ "$_loose_missing" = "0" ] || {
  echo "FATAL: a required loose file is missing from the bundle's Resources."
  echo "       These cannot come from an archive; the engine reads them off the"
  echo "       datadir or silently does without. See DEVLOG 2026-08-08 (later)."
  exit 1; }

echo "=== [4/7] license collection + audit"
mkdir -p "$RESOURCES/LICENSES"
cp "$SRC/COPYING" "$RESOURCES/"
cp "$PKG/NOTICE" "$RESOURCES/"
cp "$PKG/LICENSES/MANIFEST.tsv" "$RESOURCES/LICENSES/"
ENGINE_SRC="$SRC" "$PKG/collect-licenses.sh" "$RESOURCES/LICENSES" || { echo "FATAL: license collection failed"; exit 1; }
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
  ZIP="$OUT/BAR-Launcher-v${PORTVER}.zip"
else
  ZIP="$OUT/Recoil-macos-${VERSION}-port${PORTVER}.zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ "$IDENTITY" != "-" ] && [ "${#NOTARY_AUTH[@]}" -gt 0 ]; then
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  # re-zip with the stapled ticket
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
else
  echo "(skipped: ad-hoc signature or no notarization auth; Gatekeeper will"
  echo " reject this artifact on other machines — for local testing only)"
fi

echo "=== [6c/7] DMG (styled drag-to-Applications)"
if [ "$PROFILE" != "bar" ]; then
  DMG="(none — engine profile ships the notarized zip only)"
  echo "(skipped — the engine bundle is consumed by tooling/other launchers, not drag-installed)"
else
DMG="$OUT/BAR-Launcher-v${PORTVER}.dmg"
VOLNAME="Install BAR Launcher"
rm -f "$DMG"
DMGROOT=$(mktemp -d)
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
mkdir "$DMGROOT/.background"
cp "$PKG/dmg-background.png" "$DMGROOT/.background/background.png"
cp "$PKG/DMGIcon.icns" "$DMGROOT/.VolumeIcon.icns"   # installer icon (disc+arrow), distinct from the app

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
  if [ "${#NOTARY_AUTH[@]}" -gt 0 ]; then
    xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple "$DMG"
  fi
fi
# Brand the .dmg FILE icon. The .VolumeIcon.icns inside only brands the MOUNTED
# disk; Finder shows the generic disk-image icon for the file itself until it
# happens to thumbnail the volume icon. Attach the app icon to the file so it is
# branded on sight. This is external metadata (resource fork + custom-icon bit),
# so it does not touch the DMG bytes and the notarization staple stays valid.
ICONSETTER="$(mktemp -d)/set-file-icon"
cat > "${ICONSETTER}.swift" <<'SWIFT'
import Cocoa
let a = CommandLine.arguments
guard a.count == 3, let img = NSImage(contentsOfFile: a[1]) else { exit(2) }
exit(NSWorkspace.shared.setIcon(img, forFile: a[2], options: []) ? 0 : 1)
SWIFT
if swiftc -O "${ICONSETTER}.swift" -o "$ICONSETTER" 2>/dev/null \
   && "$ICONSETTER" "$PKG/DMGIcon.icns" "$DMG"; then
  echo "dmg icon: branded (file icon set)"
else
  echo "dmg icon: WARN could not set file icon (non-fatal)"
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
  # stock macOS has no timeout(1); Homebrew coreutils provides gtimeout
  TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) \
    || { echo "FATAL: neither timeout nor gtimeout found (brew install coreutils)"; exit 1; }
  BAR_WRITEDIR_OVERRIDE="$SMOKEDIR" BAR_CONTENT_SCOPE=lobby BAR_ASSUME_CONSENT=1 \
    "$TIMEOUT_BIN" 90 "$APP/Contents/MacOS/launcher" \
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
echo "signing:   $([ "$IDENTITY" = "-" ] && echo "ad-hoc (local only)" || echo "Developer ID$([ "${#NOTARY_AUTH[@]}" -gt 0 ] && echo " + notarized")")"
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
