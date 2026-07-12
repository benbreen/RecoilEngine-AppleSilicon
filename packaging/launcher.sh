#!/bin/bash
# BAR Launcher.app entrypoint (CFBundleExecutable).
# Responsibilities, in order:
#   1. wire the bundled Mesa Zink -> KosmicKrisp -> Metal driver env
#      (bundle-relative paths only; nothing machine-specific);
#   2. private write dir under ~/Library/Application Support (0700 — the
#      lobby stores login tokens there) with Time Machine exclusions for
#      the re-downloadable content pool;
#   3. bounded logging: rotation on, rotated logs pruned to the newest 10;
#   4. first run: quietly fetch ONLY the lobby archive (small, <1 min) —
#      the lobby's own UI then downloads game/maps with real progress bars.
#      No Terminal automation (an osascript'd Terminal triggers a macOS
#      Automation permission prompt — a first-run ticket factory);
#   5. exec the engine against the user's write dir.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)          # .../Contents/MacOS
CONTENTS=$(dirname "$HERE")
RES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
# BAR_WRITEDIR_OVERRIDE: used by the release pipeline's bundle smoke test
WRITEDIR="${BAR_WRITEDIR_OVERRIDE:-${HOME}/Library/Application Support/Beyond-All-Reason-mac}"
LOBBY_RAPID="rapid://byar-chobby:test"

fail_dialog() { # self-addressed AppleScript dialog: no Automation TCC involved
  osascript -e "display dialog \"$1\" buttons {\"OK\"} default button 1 with title \"BAR Launcher\" with icon caution" >/dev/null 2>&1 || true
}

mkdir -p "$WRITEDIR"
chmod 700 "$WRITEDIR"
# content pool is re-downloadable — keep it out of Time Machine backups
mkdir -p "$WRITEDIR/pool" "$WRITEDIR/cache"
tmutil addexclusion "$WRITEDIR/pool" "$WRITEDIR/cache" >/dev/null 2>&1 || true

ICD="$RES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
if [ ! -f "$ICD" ]; then
  fail_dialog "The application bundle is incomplete (graphics driver missing). Please re-download the game and drag it to Applications again."
  exit 1
fi

export EGL_PLATFORM=surfaceless
export VK_ICD_FILENAMES="$ICD"
export VK_DRIVER_FILES="$ICD"
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export MESA_GL_VERSION_OVERRIDE=4.6
# NB do NOT rely on DYLD_* here: the hardened runtime strips them. Zink finds
# the bundled Vulkan loader via @rpath (patches/mesa/0004) and the engine
# links bundled dylibs via LC_RPATH — the env below is only a courtesy for
# ad-hoc/dev bundles that run without library validation.
export DYLD_FALLBACK_LIBRARY_PATH="$FRAMEWORKS"
export PRD_RAPID_REPO_MASTER="https://repos-cdn.beyondallreason.dev/repos.gz"
export PRD_HTTP_SEARCH_URL="https://files-cdn.beyondallreason.dev/find"
# NB SPRING_DATADIR is NOT exported here: pr-downloader shares the engine's
# data-dir resolution and would treat $RES (the READ-ONLY bundle Resources)
# as its write dir, failing the pool write ("1 file, then Error 1"). It is
# passed inline to the engine exec only; pr-downloader uses --filesystem-writepath.

# Bounded logging: rotate per-run, prune to newest 10 rotations.
CFG="$WRITEDIR/springsettings.cfg"
if ! grep -q "^RotateLogFiles" "$CFG" 2>/dev/null; then
  echo "RotateLogFiles = 1" >> "$CFG"
fi
# First-run display defaults: WINDOWED, not fullscreen. The engine default is
# fullscreen, and a real macOS fullscreen (Spaces) traps the pointer with no
# obvious escape (cmd-tab doesn't leave it) — a first-run trap. Seed a plain
# bordered window once; the user can switch to fullscreen from settings later.
# Only seeded when the key is absent, so we never override a user's choice.
if ! grep -q "^Fullscreen " "$CFG" 2>/dev/null; then
  {
    echo "Fullscreen = 0"
    echo "WindowBorderless = 0"
    echo "XResolutionWindowed = 1600"
    echo "YResolutionWindowed = 900"
    echo "WindowPosX = 80"
    echo "WindowPosY = 80"
  } >> "$CFG"
fi

# Window branding: BAR + engine version instead of the engine's default
# ("Recoil <version>"). Refreshed each run — it is launcher-owned, not a
# user setting ({version} is expanded by the engine at startup).
if grep -q "^WindowTitle " "$CFG" 2>/dev/null; then
  grep -v "^WindowTitle " "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
fi
echo "WindowTitle = Beyond All Reason ({version})" >> "$CFG"

# Deploy BAR's canonical launcher config (extracted from dist_cfg at build
# time — the same file spring-launcher consumes on Windows/Linux). Without
# chobby_config.json the lobby falls back to game="generic", which lacks
# settingsNames, so Chobby shuts down and the screen goes black. This is the
# step the official launcher performs and we must replicate.
if [ -f "$RES/chobby_config.json" ]; then
  cp "$RES/chobby_config.json" "$WRITEDIR/chobby_config.json"   # launcher-owned; refresh each run
fi
# BAR's 87 default springsettings (render/gameplay) — merge only keys the user
# (or our display seeding above) hasn't set, so our choices always win.
if [ -f "$RES/default_springsettings.cfg" ]; then
  while IFS= read -r kv; do
    key="${kv%% =*}"
    [ -n "$key" ] || continue
    grep -q "^$key " "$CFG" 2>/dev/null || echo "$kv" >> "$CFG"
  done < "$RES/default_springsettings.cfg"
fi
if [ -d "$WRITEDIR/log" ]; then
  ls -t "$WRITEDIR/log"/*.log 2>/dev/null | tail -n +11 | while read -r f; do rm -f "$f"; done
fi

# Content check on EVERY launch (lobby + game archive), with a native progress
# window so there is immediate feedback instead of a silently bouncing dock
# icon. The lobby cannot fetch the game itself here (BYAR-Chobby's in-lobby
# game download needs the spring-launcher wrapper protocol), so this launch
# step owns game downloads AND updates — rapid is content-addressed, so a
# current install no-ops in seconds, like the official launcher's update check.
# The SUCCESS SENTINEL distinguishes first run (failure is fatal — nothing to
# play) from later launches (failure is soft — play offline on existing
# content). BAR_SKIP_CONTENT_CHECK=1 skips entirely (harness/testing).
DONE_SENTINEL="$WRITEDIR/.lobby-installed"
LOG="$WRITEDIR/first-run-download.log"
HELPER="$HERE/progress-window"

# Dialog versioning + acknowledgement files (in the writedir, so they persist
# across app reinstalls — the CONTENT sentinel above must NEVER be conflated
# with consent, which was the old skip-the-disclaimer bug). Bump a *_VERSION
# to re-show that dialog once.
CONSENT_VERSION="1"
NOTICE_VERSION="1"
CONSENT_ACK="$WRITEDIR/.consent-ack"
NOTICE_ACK="$WRITEDIR/.notice-ack"
MESSAGE_SEEN="$WRITEDIR/.message-seen"
# Remote message config (announcements / kill-switch); overridable for testing.
MESSAGE_CONFIG_URL="${BAR_MESSAGE_CONFIG_URL:-https://raw.githubusercontent.com/benbreen/recoil-apple-messages/main/messages.json}"
PORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS/Info.plist" 2>/dev/null || echo 0)"

if [ "${BAR_SKIP_CONTENT_CHECK:-0}" != "1" ]; then
  FIRST_RUN=1; [ -f "$DONE_SENTINEL" ] && FIRST_RUN=0

  if [ "${BAR_ASSUME_CONSENT:-0}" != "1" ]; then
    # 1) REMOTE messages (announcements + kill-switch for bad builds).
    #    Fail-open by design: offline / config host down -> exit 0, continue.
    #    THIS is exactly why the disclaimer (step 3) is LOCAL and hardcoded —
    #    a flaky connection must never be able to skip it. A blocking message
    #    returns 2 -> quit.
    if [ -x "$HERE/message-check" ]; then
      "$HERE/message-check" --config-url "$MESSAGE_CONFIG_URL" \
        --app-version "$PORT_VERSION" --seen-file "$MESSAGE_SEEN" --timeout 4
      [ "$?" = "2" ] && exit 0
    fi
    if [ -x "$HERE/consent-dialog" ]; then
      # 2) ONLINE PLAY IS DISABLED notice — LOCAL, shown once per NOTICE_VERSION.
      if [ -f "$RES/.online-play-disabled" ] && \
         [ "$(cat "$NOTICE_ACK" 2>/dev/null)" != "$NOTICE_VERSION" ]; then
        "$HERE/consent-dialog" --notice "ONLINE PLAY IS DISABLED in this build while I seek approval from the creators of Beyond All Reason to connect to their community servers.

The game opens on a sign-in screen first — press Cancel to reach everything that works offline: skirmish against AI, replays, and local-network (LAN) games.

If you do try to sign in or open an online menu, it will simply fail to reach the server — there is no in-game message explaining why, because online play is blocked outside the game, not inside it.

I hope online play can be enabled very soon." || true
        echo "$NOTICE_VERSION" > "$NOTICE_ACK"
      fi
      # 3) DISCLAIMER / consent — LOCAL and hardcoded (never network-gated).
      #    Shown once per CONSENT_VERSION; tracked by .consent-ack (independent
      #    of content state). Quit exits. server shown = the host
      #    download-content.sh actually fetches from (single source of truth).
      if [ "$(cat "$CONSENT_ACK" 2>/dev/null)" != "$CONSENT_VERSION" ]; then
        CONTENT_SERVER="$("$RES/download-content.sh" --print-server 2>/dev/null)"
        "$HERE/consent-dialog" --server "${CONTENT_SERVER:-the BAR content network}" || exit 0
        echo "$CONSENT_VERSION" > "$CONSENT_ACK"
      fi
    fi
  fi
  : > "$LOG"
  # Show the progress window immediately (fed via a fifo). If the helper is
  # missing/unrunnable, we degrade gracefully to a headless download + dialog.
  FIFO=""; HPID=""
  if [ -x "$HELPER" ]; then
    FIFO=$(mktemp -u)/pw.fifo; mkdir -p "$(dirname "$FIFO")"; mkfifo "$FIFO"
    "$HELPER" < "$FIFO" & HPID=$!
    exec 4>"$FIFO"   # keep the write end open for the whole download
    if [ "$FIRST_RUN" = "1" ]; then
      printf 'S %s\n' "Preparing Beyond All Reason (first run)…" >&4
    else
      printf 'S %s\n' "Checking for updates…" >&4
    fi
  fi

  # Run the downloader in the FOREGROUND (so $? is its real exit code — a
  # `while read < <(cmd)` loop cannot recover cmd's status on macOS bash 3.2)
  # and stream its @-protocol through a fifo to a background forwarder that
  # drives the window; everything is tee'd to the log for debugging.
  SFIFO="$(mktemp -u).status"; mkfifo "$SFIFO"
  ( while IFS= read -r line; do
      printf '%s\n' "$line" >> "$LOG"
      case "$line" in
        @S\ *) [ -n "$HPID" ] && printf 'S %s\n' "${line#@S }" >&4 ;;
        @D\ *) [ -n "$HPID" ] && printf 'D %s\n' "${line#@D }" >&4 ;;
        @P\ *) [ -n "$HPID" ] && printf 'P %s\n' "${line#@P }" >&4 ;;
        @I)    [ -n "$HPID" ] && printf 'I\n' >&4 ;;
      esac
    done < "$SFIFO" ) & FWD_PID=$!

  PRD="$HERE/pr-downloader" "$RES/download-content.sh" --writedir "$WRITEDIR" \
      > "$SFIFO" 2>>"$LOG"
  RC=$?
  wait "$FWD_PID" 2>/dev/null; rm -f "$SFIFO"

  # classified failure (if any) is the last @E: line in the log
  ERR_CODE=""; ERR_TEXT=""
  ERR_LINE=$(grep '^@E:' "$LOG" 2>/dev/null | tail -1)
  if [ -n "$ERR_LINE" ]; then
    ERR_CODE="${ERR_LINE#@E:}"; ERR_CODE="${ERR_CODE%% *}"
    ERR_TEXT="${ERR_LINE#@E:* }"
  fi

  if [ "$RC" -eq 0 ] && [ -z "$ERR_CODE" ]; then
    touch "$DONE_SENTINEL"
    [ -n "$HPID" ] && { exec 4>&-; wait "$HPID" 2>/dev/null; }   # EOF closes window
  elif [ "$FIRST_RUN" = "1" ]; then
    # First run: nothing playable exists — close the progress window, then show
    # the rich error dialog (same one the engine uses): classified message + a
    # scrollable this-session log to paste.
    [ -n "$HPID" ] && { exec 4>&-; kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; }
    MSG="${ERR_TEXT:-The first-run download failed (code ${RC}).}"
    ERRHELP="$HERE/error-dialog"
    if [ -x "$ERRHELP" ]; then
      "$ERRHELP" --title "BAR Launcher" --message "[${ERR_CODE:-unknown}] $MSG" --logfile "$LOG"
    else
      fail_dialog "$MSG"$'\n\n'"Details: $LOG"
    fi
    exit 1
  else
    # Update check failed on an already-working install (offline, CDN hiccup):
    # play on existing content; the next launch retries. Log, don't block.
    [ -n "$HPID" ] && { exec 4>&-; kill "$HPID" 2>/dev/null; wait "$HPID" 2>/dev/null; }
    printf 'update check failed (code %s %s) — continuing on existing content\n' \
      "$RC" "${ERR_CODE:-}" >> "$LOG"
  fi
fi

# BAR_INFOLOG lets the engine's error dialog (Platform::MsgBox) attach the
# full this-session log to any fatal it shows.
SPRING_DATADIR="$RES" BAR_INFOLOG="$WRITEDIR/infolog.txt" \
  exec "$HERE/spring" --write-dir "$WRITEDIR" --menu "$LOBBY_RAPID" "$@"
