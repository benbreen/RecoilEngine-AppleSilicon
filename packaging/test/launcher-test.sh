#!/bin/bash
# launcher-test.sh — integration harness for launcher.sh startup gating.
# Stages a fake .app whose helpers (message-check, consent-dialog, spring, …)
# are recording stubs, then drives the REAL launcher through every path:
# versioned consent/notice acks, message-check kill-switch, quit handling,
# assume-consent + skip escapes, and the online-disabled marker. No GUI, no
# network, no engine. This is the coverage the original "disclaimer skipped
# because content already existed" bug needed.
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=$(mktemp -d)
# kill any launcher/stub child still referencing our sandbox before removing it
# (so a killed run can never orphan a launcher that then pops a GUI dialog)
trap 'pkill -f "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT INT TERM
APP="$ROOT/BAR Launcher.app"; MACOS="$APP/Contents/MacOS"; RES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RES/vulkan/icd.d"
export CALLS="$ROOT/calls.log"

cp "$PKG/launcher.sh" "$MACOS/launcher"; chmod +x "$MACOS/launcher"

# hermetic PATH: stub system tools the launcher touches (tmutil talks to
# backupd and can hang) so the test never depends on machine state.
STUBBIN="$ROOT/bin"; mkdir -p "$STUBBIN"
printf '#!/bin/bash\nexit 0\n' > "$STUBBIN/tmutil"; chmod +x "$STUBBIN/tmutil"
export PATH="$STUBBIN:$PATH"

# --- recording stubs -------------------------------------------------------
cat > "$MACOS/message-check" <<'S'
#!/bin/bash
echo "message-check" >> "$CALLS"; exit ${STUB_MC_EXIT:-0}
S
cat > "$MACOS/consent-dialog" <<'S'
#!/bin/bash
case "$*" in
  *--notice*) echo "consent-notice" >> "$CALLS"; exit 0;;
  *--server*) echo "consent-server" >> "$CALLS"; exit ${STUB_CONSENT_EXIT:-0};;
esac
S
cat > "$MACOS/spring" <<'S'
#!/bin/bash
echo "spring-launched" >> "$CALLS"; exit 0
S
cat > "$MACOS/error-dialog" <<'S'
#!/bin/bash
echo "error-dialog" >> "$CALLS"; exit 0
S
cat > "$RES/download-content.sh" <<'S'
#!/bin/bash
case "$*" in *--print-server*) echo "repos-cdn.beyondallreason.dev"; exit 0;; esac
printf '@S go\n@P 100\n@DONE\n'; printf 'CONTENT_OK\n' >&2; exit ${STUB_DL_EXIT:-0}
S
chmod +x "$MACOS/message-check" "$MACOS/consent-dialog" "$MACOS/spring" "$MACOS/error-dialog" "$RES/download-content.sh"
echo '{}' > "$RES/chobby_config.json"
echo '{}' > "$RES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1</string></dict></plist>
P

pass=0; fail=0
ok()  { pass=$((pass+1)); printf "  ok   %s\n" "$1"; }
bad() { fail=$((fail+1)); printf "  FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "       calls: %s\n" "$2"; }

# run <writedir> [env assignments...]  -> populates $CALLS (reset each run)
run() { : > "$CALLS"; local wd="$1"; shift; timeout 15 env "$@" BAR_WRITEDIR_OVERRIDE="$wd" \
        "$MACOS/launcher" >/dev/null 2>&1 </dev/null; [ $? -eq 124 ] && echo "TIMEOUT" >> "$CALLS"; }
has()  { grep -qx "$1" "$CALLS"; }
calls(){ tr '\n' ',' < "$CALLS"; }
online_on()  { : > "$RES/.online-play-disabled"; }
online_off() { rm -f "$RES/.online-play-disabled"; }

echo "== first run: notice + disclaimer shown, acks written, engine launched =="
online_on; WD="$ROOT/w1"; run "$WD"
{ has message-check && has consent-notice && has consent-server && has spring-launched; } \
  && ok "message-check + notice + disclaimer + launch" || bad "first run" "$(calls)"
[ "$(cat "$WD/.consent-ack" 2>/dev/null)" = "1" ] && ok ".consent-ack written (v1)" || bad "consent-ack"
[ "$(cat "$WD/.notice-ack"  2>/dev/null)" = "1" ] && ok ".notice-ack written (v1)"  || bad "notice-ack"

echo "== second run (same writedir): acked dialogs NOT reshown =="
run "$WD"
{ has message-check && ! has consent-notice && ! has consent-server && has spring-launched; } \
  && ok "notice + disclaimer suppressed once acked; message-check still runs" || bad "second run" "$(calls)"

echo "== the original bug: content present but consent NOT yet acked =="
WD2="$ROOT/w2"; mkdir -p "$WD2"; : > "$WD2/.lobby-installed"   # content 'already installed'
run "$WD2"
has consent-server && ok "disclaimer shows despite .lobby-installed (bug fixed)" || bad "bug regression" "$(calls)"

echo "== version bump re-asks once =="
echo 0 > "$WD/.consent-ack"; echo 0 > "$WD/.notice-ack"   # simulate CONSENT/NOTICE_VERSION bump
run "$WD"
{ has consent-server && has consent-notice; } && ok "stale ack -> both re-shown once" || bad "bump" "$(calls)"
run "$WD"
{ ! has consent-server && ! has consent-notice; } && ok "re-acked -> quiet again" || bad "bump re-ack" "$(calls)"

echo "== disclaimer Quit stops launch =="
WD3="$ROOT/w3"; run "$WD3" STUB_CONSENT_EXIT=1
{ has consent-server && ! has spring-launched; } && ok "Quit at disclaimer -> engine NOT launched" || bad "quit" "$(calls)"

echo "== kill-switch (message-check exit 2) stops launch, before dialogs =="
WD4="$ROOT/w4"; run "$WD4" STUB_MC_EXIT=2
{ has message-check && ! has consent-server && ! has spring-launched; } \
  && ok "message-check=2 -> quit before disclaimer, no launch" || bad "killswitch" "$(calls)"

echo "== online-disabled marker gates the notice =="
online_off; WD5="$ROOT/w5"; run "$WD5"
{ ! has consent-notice && has consent-server && has spring-launched; } \
  && ok "no marker -> no online notice; disclaimer still shown" || bad "no-marker" "$(calls)"
online_on

echo "== BAR_ASSUME_CONSENT / BAR_SKIP_CONTENT_CHECK escapes =="
WD6="$ROOT/w6"; run "$WD6" BAR_ASSUME_CONSENT=1
{ ! has message-check && ! has consent-server && ! has consent-notice && has spring-launched; } \
  && ok "assume-consent -> no dialogs, still launches" || bad "assume-consent" "$(calls)"
WD7="$ROOT/w7"; run "$WD7" BAR_SKIP_CONTENT_CHECK=1
{ ! has message-check && ! has consent-server && has spring-launched; } \
  && ok "skip-content-check -> whole block skipped, still launches" || bad "skip" "$(calls)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
