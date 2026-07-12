#!/bin/bash
# bundle-smoke.sh — drive the SIGNED .app the way a real user's double-click
# does, headlessly, so first-run + engine-boot can be iterated without a human.
#
# Mimics LaunchServices launch conditions that a terminal run does NOT:
#   - scrubbed environment (no inherited DYLD_*/SPRING_*/PATH from a dev shell)
#   - a throwaway write dir (true first-run every time; --keep to reuse)
#   - a bounded run; the engine is expected to reach its menu and keep running,
#     so we consider "still alive at the cap AND driver loaded AND no fatal"
#     a PASS, and classify anything else.
#
# Usage: bundle-smoke.sh [--app PATH] [--cap SECS] [--keep] [--writedir DIR]
# Exit 0 = PASS. Nonzero = a classified failure is printed.
set -uo pipefail

APP="${1:-release-artifacts/BAR Launcher.app}"
CAP=90
KEEP=0
WD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2;;
    --cap) CAP=$2; shift 2;;
    --keep) KEEP=1; shift;;
    --writedir) WD=$2; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done
APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")   # absolutize
MACOS="$APP/Contents/MacOS"
[ -x "$MACOS/launcher" ] || { echo "FAIL: no launcher in $APP"; exit 2; }

[ -n "$WD" ] || WD=$(mktemp -d)
mkdir -p "$WD"
INFOLOG="$WD/infolog.txt"
STDOUT="$WD/launcher-stdout.log"
DLLOG="$WD/first-run-download.log"

echo "=== bundle-smoke: $(basename "$APP") cap=${CAP}s writedir=$WD ==="

# LaunchServices-like: a normal login env but SCRUBBED of the dev-shell leaks
# a double-clicked app never sees (DYLD_*/SPRING_*/graphics-stack vars). Using
# a fully empty env (env -i) is unrealistic and breaks basic tool lookup.
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES \
    -u SPRING_DATADIR -u SPRING_WRITEDIR -u MESA_LOADER_DRIVER_OVERRIDE \
    -u GALLIUM_DRIVER -u MESA_GL_VERSION_OVERRIDE -u VK_ICD_FILENAMES \
    -u VK_DRIVER_FILES -u EGL_PLATFORM -u CPATH \
    __CFBundleIdentifier=dev.bar-macos.engine \
    BAR_WRITEDIR_OVERRIDE="$WD" \
    BAR_CONTENT_SCOPE=lobby \
    BAR_ASSUME_CONSENT=1 \
  timeout "$CAP" "$MACOS/launcher" > "$STDOUT" 2>&1 &
LPID=$!

# wait for a terminal condition: driver loaded (progress past boot), a fatal,
# or process exit / cap.
DRIVER=0; FATAL=""
SECS=0
while kill -0 "$LPID" 2>/dev/null; do
  if [ "$DRIVER" = 0 ] && grep -q "KOSMICKRISP_LOADED" "$STDOUT" "$INFOLOG" 2>/dev/null; then
    DRIVER=1; echo "[t+${SECS}s] driver loaded"
  fi
  if F=$(grep -m1 -E "Fatal:|\[ExitSpringProcess\]|software renderer" "$INFOLOG" "$STDOUT" 2>/dev/null); then
    FATAL="$F"; break
  fi
  sleep 2; SECS=$((SECS+2))
done

# if it reached the menu and is still alive at cap, that's success
ALIVE=0; kill -0 "$LPID" 2>/dev/null && ALIVE=1
MENU=0; grep -q -E "LuaMenuController.*using menu archive|GameParticleSystem|Using VFS|Loading Springlobby|SelectMenu|CLuaMenu" "$INFOLOG" 2>/dev/null && MENU=1
[ "$ALIVE" = 1 ] && { kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null; }
RC=$?

emit_tail() { echo "--- last 25 infolog lines ---"; tail -25 "$INFOLOG" 2>/dev/null | cut -c1-140; }

# A collapsed lobby (global Chobby nil) storms "index field 'Chobby'" errors
# and shows a blank screen. NB "Chobby Shutdown" is ALSO logged on NORMAL exit
# (when this harness kills the app), so it is NOT a collapse signal — only the
# nil-cascade is. Count RUNTIME LuaMenu errors, excluding teardown ("In
# Shutdown()") noise that fires as we kill the process.
CHOBBY_DOWN=0; grep -q "index field 'Chobby'" "$INFOLOG" 2>/dev/null && CHOBBY_DOWN=1
LUAERR=$(grep "LuaMenu\] Error" "$INFOLOG" 2>/dev/null | grep -cv "In Shutdown()" || echo 0)

VERDICT="UNKNOWN"; CODE=1
if grep -q "software renderer" "$INFOLOG" "$STDOUT" 2>/dev/null; then
  VERDICT="FAIL:driver-fallback (llvmpipe)"; CODE=5
elif grep -q "@E:" "$DLLOG" 2>/dev/null; then
  VERDICT="FAIL:download $(grep -m1 '@E:' "$DLLOG")"; CODE=6
elif [ -n "$FATAL" ]; then
  VERDICT="FAIL:engine-fatal — $FATAL"; CODE=7
elif [ "$CHOBBY_DOWN" = 1 ]; then
  VERDICT="FAIL:lobby-collapsed (Chobby shut down; blank screen; ${LUAERR} LuaMenu errors) — likely missing chobby_config.json / content"; CODE=10
elif [ "$DRIVER" = 1 ] && { [ "$ALIVE" = 1 ] || [ "$MENU" = 1 ]; } && [ "${LUAERR:-0}" -lt 5 ]; then
  VERDICT="PASS (driver loaded, lobby initialized, ${LUAERR} LuaMenu errors)"; CODE=0
elif [ "$DRIVER" = 1 ]; then
  VERDICT="FAIL:menu-degraded (${LUAERR} LuaMenu errors)"; CODE=8
else
  VERDICT="FAIL:never-loaded-driver"; CODE=9
fi

echo "=== VERDICT: $VERDICT ==="
[ "$CODE" = 0 ] || emit_tail
echo "logs: $STDOUT | $INFOLOG | $DLLOG"
[ "$KEEP" = 1 ] || { [ "$CODE" = 0 ] && rm -rf "$WD"; }
exit $CODE
