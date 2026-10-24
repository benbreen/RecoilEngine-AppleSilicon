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

fail_dialog() { # self-addressed AppleScript dialog: no Automation TCC involved.
  # activate + frontmost so it isn't lost behind another app's window.
  osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events"
  activate
  display dialog "$1" buttons {"OK"} default button 1 with title "BAR Launcher" with icon caution
end tell
OSA
}

mkdir -p "$WRITEDIR"
chmod 700 "$WRITEDIR"
if [ ! -d "$WRITEDIR" ] || [ ! -w "$WRITEDIR" ]; then
  # Without a writable data dir NOTHING downstream can work (settings, logs,
  # content, engine write dir) — fail here with a clear reason instead of a
  # cascade of confusing errors later.
  fail_dialog "Beyond All Reason could not create its data folder:

$WRITEDIR

Check that your disk is not full and that this folder is not locked, then try again."
  exit 1
fi
# Single-instance lock on the shared write dir. Finder enforces one instance
# PER BUNDLE, but two copies of the app (e.g. a stale install plus a new one)
# share this write dir — two concurrent pr-downloaders would race the same
# pool .tmp paths and can rename a corrupt file into the pool. mkdir is the
# atomic primitive; a dead owner (crash, force-quit) is detected by pid
# liveness and the lock reclaimed. Held for our whole lifetime — the exec'd
# engine keeps our pid, so a second launch while playing is also refused.
LOCK="$WRITEDIR/.launcher-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  OLDPID=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    fail_dialog "Beyond All Reason is already running or updating. If you cannot find its window, wait a few seconds and try again."
    exit 0
  fi
  rm -rf "$LOCK"
  if ! mkdir "$LOCK" 2>/dev/null; then
    fail_dialog "Beyond All Reason could not claim its data folder (another copy may be starting). Please try again."
    exit 0
  fi
fi
echo $$ > "$LOCK/pid"
# content pool is re-downloadable — keep it out of Time Machine backups.
# Fire-and-forget: tmutil talks to backupd and can block (stuck daemon /
# permissions); this exclusion is cosmetic and must never delay launch.
mkdir -p "$WRITEDIR/pool" "$WRITEDIR/cache"
{ tmutil addexclusion "$WRITEDIR/pool" "$WRITEDIR/cache" >/dev/null 2>&1 || true; } &

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

# Sim/draw balance: the engine defaults (MinDrawFPS=2, MinSimDrawBalance=0.15)
# let rendering starve to 2 fps during sim catch-up bursts, which players see
# as ~1s "freezes"/pause-flicker in big battles on Apple-class sim times
# (issue #5). Tuned values eliminated all >100ms battle-window draw gaps in an
# interleaved n=4 A/B (DEVLOG 2026-07-21) at the cost of slightly slower sim
# catch-up. Seeded only when absent so user choices always win.
if ! grep -q "^MinDrawFPS " "$CFG" 2>/dev/null; then
  echo "MinDrawFPS = 10" >> "$CFG"
fi
if ! grep -q "^MinSimDrawBalance " "$CFG" 2>/dev/null; then
  echo "MinSimDrawBalance = 0.25" >> "$CFG"
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
# "potato GPU" mitigation (2026-08-04). BAR's own gui_options.lua classifies the
# GPU by VENDOR, and its chain is: no-GL4 -> potato; NVidia -> check VRAM;
# Intel -> needs "arc"; AMD -> needs "rx"/"r9"; else -> potato. Apple Silicon via
# zink/KosmicKrisp reports vendor "Mesa" and matches none of them, so EVERY Apple
# Mac lands in the catch-all else and is branded low-end (introduced upstream
# 2026-06-30 in 336cf9d9, so v0.11 and v0.12 shipped with it too). On FIRST LAUNCH
# only, that branch writes: water 0, Shadows 0, ShadowMapSize 1024, MSAALevel 0 --
# i.e. it permanently disables water and shadows on an M2 Ultra.
#
# We cannot fix the detection: game content is reference-only (PORTING_PRINCIPLES
# §0) and ships from BAR's CDN, so there is nothing local to patch. The proper fix
# is an Apple/Metal branch upstream -- see docs/OUTSTANDING.md; this is the
# interim, port-side mitigation.
#
# Mechanism: that whole block is gated on `firstlaunchsetupDone`, which BAR
# persists as `firsttimesetupDone` in its LuaUI config. Seeding that marker makes
# BAR skip the downgrade. Because skipping it also skips the GOOD first-launch
# defaults, we reproduce those here (they are plain config values).
# Deliberately seeded ONLY when the config is absent, i.e. a genuinely fresh
# install -- a returning user's file is never touched, and everything below stays
# changeable from BAR's own settings UI.
BYAR_CFG="$WRITEDIR/LuaUI/Config/BYAR.lua"
if [ ! -f "$BYAR_CFG" ]; then
  mkdir -p "$WRITEDIR/LuaUI/Config"
  cat > "$BYAR_CFG" <<'BYAREOF'
-- Widget Custom data and order, order = 0 disabled widget
-- Seeded by the macOS launcher on first run: see the "potato GPU" note in
-- packaging/launcher.sh. Only `firsttimesetupDone` is pre-set, so BAR does not
-- misclassify Apple Silicon and disable water/shadows. No widget order is
-- specified, so every widget keeps its stock default state.
return {
	allowUserWidgets = true,
	data = {
		Options = {
			firsttimesetupDone = true,
			desiredWaterValue = 4,
		},
	},
}
BYAREOF
  # the non-potato first-launch defaults BAR would otherwise have applied.
  # CamMode is 2 (Spring), not the 3 BAR writes: BAR's block sets CamMode 3
  # and then sends "viewspring", so the session runs the Spring camera and its
  # "Camera Remember" widget persists mode 2 from then on. We cannot send the
  # command, and seeding 3 alone left every Mac install on Rotatable Overhead
  # for good: middle-drag rotates instead of panning, the wheel zooms in
  # place instead of toward the cursor (issue #13).
  for kv in "Water = 4" "MaxParticles = 12000" "CamMode = 2"; do
    key="${kv%% =*}"
    grep -q "^$key " "$CFG" 2>/dev/null || echo "$kv" >> "$CFG"
  done
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
# The sentinel RECORDS WHICH content set was installed (a digest of
# Resources/content_tags): "a check once succeeded" is not the same claim as
# "the content this build needs is on disk". v0.11 wrote an empty sentinel
# after fetching the dummy byar:stable package, so on a v0.11 install the
# first REAL game download (v0.12, byar:test, ~2-3 GB) looked like an update.
DONE_SENTINEL="$WRITEDIR/.lobby-installed"
# digest of the tag list download-content.sh installs; changes whenever the
# required content set does. Missing content_tags => downloader's built-in list.
CONTENT_SIG="$(shasum "$RES/content_tags" 2>/dev/null | cut -c1-12)"
CONTENT_SIG="${CONTENT_SIG:-builtin}"
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
# Remote message config (announcements / kill-switch). Source baked at build
# time (release-build.sh --messages-config/--messages-local -> staged
# .message-config-url); BAR_MESSAGE_CONFIG_URL overrides at runtime.
MESSAGE_CONFIG_URL="${BAR_MESSAGE_CONFIG_URL:-$(cat "$RES/.message-config-url" 2>/dev/null || echo "https://raw.githubusercontent.com/benbreen/RecoilEngine-AppleSilicon/main/message-config/messages.json")}"
PORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CONTENTS/Info.plist" 2>/dev/null || echo 0)"

if [ "${BAR_SKIP_CONTENT_CHECK:-0}" != "1" ]; then
  FIRST_RUN=1; [ -f "$DONE_SENTINEL" ] && FIRST_RUN=0
  # Is skipping this check SAFE — i.e. is there a complete, playable install to
  # fall back on? Stricter than FIRST_RUN on purpose, and deliberately NOT tied
  # to it: FIRST_RUN governs whether a download failure is fatal, and a stale
  # signature must never turn a flaky network into "you cannot launch". It only
  # gates the Skip button, where being wrong strands the user with no game.
  #   1. the sentinel names the content set THIS build installs, and
  #   2. package indexes actually exist on disk (guards a wiped/moved pool).
  CAN_SKIP=0
  if [ "$FIRST_RUN" = "0" ] && \
     [ "$(cat "$DONE_SENTINEL" 2>/dev/null)" = "$CONTENT_SIG" ]; then
    for _sdp in "$WRITEDIR"/packages/*.sdp; do
      [ -e "$_sdp" ] && { CAN_SKIP=1; break; }
    done
  fi

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
  # Ignore SIGPIPE for the whole content-check section: if the user quits the
  # progress window, OUR OWN final status printfs to the dead fifo would
  # otherwise kill the launcher (exit 141) right before it starts the engine.
  # Restored to default just before exec below — the engine must not inherit
  # an ignored SIGPIPE.
  trap '' PIPE
  # Show the progress window immediately (fed via a fifo). If the helper is
  # missing/unrunnable — or fifo creation fails — we degrade gracefully to a
  # headless download + dialog rather than dying on a broken redirection.
  # millisecond clock for the min-display hold below ­— whole-second date(1)
  # granularity can under-hold by up to a second at the boundary
  now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)' 2>/dev/null \
             || echo $(( $(date +%s) * 1000 )); }
  FIFO=""; FIFODIR=""; HPID=""; SKIP_FLAG=""; T_WINDOW=$(now_ms)
  if [ -x "$HELPER" ]; then
    FIFODIR=$(mktemp -d 2>/dev/null || true)
    if [ -n "$FIFODIR" ] && mkfifo "$FIFODIR/pw.fifo" 2>/dev/null; then
      FIFO="$FIFODIR/pw.fifo"
      # Skip button: only when there is something playable to fall back to.
      # The window touches this file when clicked; the poll loop below acts.
      [ "$CAN_SKIP" = "1" ] && SKIP_FLAG="$FIFODIR/skip-requested"
      # Double-fork: the helper is reparented to launchd, NOT kept as our
      # child. The success path deliberately does not wait for it (the window
      # enforces a minimum on-screen time and must out-live our exec of the
      # engine without leaving a zombie under it).
      # REDIRECTION ORDER MATTERS: >/dev/null must come FIRST. Redirections
      # apply left-to-right, and opening the fifo for reading blocks until we
      # open the write end below — if the helper still held the command-
      # substitution pipe while blocked there, this line could never finish
      # and the launcher would deadlock before showing anything.
      if [ -n "$SKIP_FLAG" ]; then
        HPID=$( ( "$HELPER" --skip-file "$SKIP_FLAG" >/dev/null 2>&1 < "$FIFO" & echo $! ) )
      else
        HPID=$( ( "$HELPER" >/dev/null 2>&1 < "$FIFO" & echo $! ) )
      fi
      exec 4>"$FIFO"   # keep the write end open for the whole download
      if [ "$FIRST_RUN" = "1" ]; then
        printf 'S %s\n' "Preparing Beyond All Reason (first run)…" >&4
      else
        printf 'S %s\n' "Checking for updates…" >&4
      fi
    fi
  fi
  # single cleanup point for the fifo + its temp dir (unlinking an open fifo
  # is safe — the helper keeps its file descriptor)
  cleanup_fifo() { [ -n "$FIFODIR" ] && rm -rf "$FIFODIR" 2>/dev/null; FIFO=""; FIFODIR=""; }

  # ---- update integrity snapshot ------------------------------------------
  # The engine resolves rapid:// tags from WRITEDIR/rapid/**/versions.gz
  # (RapidHandler.cpp), and pr-downloader refreshes that metadata during the
  # RESOLVE phase — before the actual archive download. A half-finished update
  # (train wifi, skip button, crash) therefore leaves the tag pointing at a
  # package that is not on disk, breaking a previously-working install even
  # though the old files are all still present (pool/packages are append-only,
  # nothing is ever overwritten). Snapshot the metadata before the check and
  # restore it on ANY non-success — the old version then prevails exactly.
  RAPID_DIR="$WRITEDIR/rapid"; RAPID_BAK="$WRITEDIR/rapid.pre-update"
  restore_rapid() {
    if [ -d "$RAPID_BAK" ]; then
      rm -rf "$RAPID_DIR"; mv "$RAPID_BAK" "$RAPID_DIR" 2>/dev/null
      printf 'rapid metadata restored — pre-update version prevails\n' >> "$LOG"
    fi
  }
  # a leftover backup means the previous update was interrupted mid-write
  # (crash/force-quit): roll back FIRST so this run starts from a good state
  restore_rapid
  [ -d "$RAPID_DIR" ] && { rm -rf "$RAPID_BAK"; cp -R "$RAPID_DIR" "$RAPID_BAK" 2>/dev/null; }

  # Run the downloader in the BACKGROUND and poll it, so a Skip click can
  # interrupt it mid-download (`wait <pid>` still recovers its real exit
  # code on macOS bash 3.2). Its @-protocol streams through a fifo to a
  # background forwarder that drives the window; everything lands in the log.
  SKIPPED=0
  poll_downloader() { # sets RC; kills the downloader tree if Skip is clicked
    local dl_pid=$1
    while kill -0 "$dl_pid" 2>/dev/null; do
      if [ -n "$SKIP_FLAG" ] && [ -f "$SKIP_FLAG" ]; then
        SKIPPED=1
        printf 'user clicked Skip — stopping the update\n' >> "$LOG"
        pkill -P "$dl_pid" 2>/dev/null   # pr-downloader + pipeline helpers
        kill "$dl_pid" 2>/dev/null
        break
      fi
      sleep 0.25
    done
    wait "$dl_pid" 2>/dev/null; RC=$?
  }
  SFIFO="$(mktemp -u).status"
  if mkfifo "$SFIFO" 2>/dev/null; then
    # trap '' PIPE: if the progress helper dies (user quits it, crash), a
    # bare printf >&4 would take SIGPIPE and kill this forwarder — and the
    # downloader would then block forever on a full fifo with no UI at all.
    # The forwarder must keep draining $SFIFO no matter what happens to the
    # window; failed writes to fd 4 are simply discarded.
    ( trap '' PIPE
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$LOG"
        case "$line" in
          @S\ *) [ -n "$HPID" ] && printf 'S %s\n' "${line#@S }" >&4 2>/dev/null ;;
          @D\ *) [ -n "$HPID" ] && printf 'D %s\n' "${line#@D }" >&4 2>/dev/null ;;
          @P\ *) [ -n "$HPID" ] && printf 'P %s\n' "${line#@P }" >&4 2>/dev/null ;;
          @I)    [ -n "$HPID" ] && printf 'I\n' >&4 2>/dev/null ;;
        esac
      done < "$SFIFO" ) & FWD_PID=$!

    PRD="$HERE/pr-downloader" "$RES/download-content.sh" --writedir "$WRITEDIR" \
        > "$SFIFO" 2>>"$LOG" & DL_PID=$!
    poll_downloader "$DL_PID"
    wait "$FWD_PID" 2>/dev/null; rm -f "$SFIFO"
  else
    # No fifo (tmp exhausted?): headless download, everything straight to the
    # log so @E classification still works; the window (if any) just idles.
    PRD="$HERE/pr-downloader" "$RES/download-content.sh" --writedir "$WRITEDIR" \
        >> "$LOG" 2>&1 & DL_PID=$!
    poll_downloader "$DL_PID"
  fi

  # classified failure (if any) is the last @E: line in the log
  ERR_CODE=""; ERR_TEXT=""
  ERR_LINE=$(grep '^@E:' "$LOG" 2>/dev/null | tail -1)
  if [ -n "$ERR_LINE" ]; then
    ERR_CODE="${ERR_LINE#@E:}"; ERR_CODE="${ERR_CODE%% *}"
    ERR_TEXT="${ERR_LINE#@E:* }"
  fi

  if [ "$SKIPPED" = "1" ]; then
    # User chose to play NOW (train/plane, half-working wifi): stop cleanly,
    # roll the tag metadata back — the pre-update version prevails intact.
    restore_rapid
    if [ -n "$HPID" ]; then
      printf 'F %s\n' "Update skipped" >&4 2>/dev/null
      printf 'D %s\n' "Launching game…" >&4 2>/dev/null
      exec 4>&-
    fi
    cleanup_fifo
    printf 'update skipped by user — playing existing content; next launch retries\n' >> "$LOG"
  elif [ "$RC" -eq 0 ] && [ -z "$ERR_CODE" ]; then
    printf '%s\n' "$CONTENT_SIG" > "$DONE_SENTINEL"   # WHAT is installed, not just THAT
    rm -rf "$RAPID_BAK"   # update is fully on disk — snapshot no longer needed
    if [ -n "$HPID" ]; then
      # Finished state: bar and Skip button disappear, result + launch note.
      if [ "$FIRST_RUN" = "1" ]; then
        printf 'F %s\n' "Beyond All Reason is ready" >&4 2>/dev/null
      else
        printf 'F %s\n' "Beyond All Reason is up-to-date" >&4 2>/dev/null
      fi
      printf 'D %s\n' "Launching game…" >&4 2>/dev/null
      # The result must be READABLE: hold until the window has been up ≥3s
      # in total before we proceed into the game (a no-op check finishes in
      # well under a second — without this the text is an unreadable flash).
      EL=$(( $(now_ms) - T_WINDOW ))
      if [ "$EL" -lt 3000 ]; then
        REM=$(( 3000 - EL ))
        sleep "$(printf '%d.%03d' $(( REM / 1000 )) $(( REM % 1000 )))"
      fi
      exec 4>&-
    fi
    cleanup_fifo
  elif [ "$FIRST_RUN" = "1" ]; then
    # First run: nothing playable exists — close the progress window, then show
    # the rich error dialog (same one the engine uses): classified message + a
    # scrollable this-session log to paste.
    restore_rapid   # roll partial first-run metadata back to a clean slate
    [ -n "$HPID" ] && { exec 4>&-; kill "$HPID" 2>/dev/null; }
    cleanup_fifo
    MSG="${ERR_TEXT:-The first-run download failed (code ${RC}).}"
    ERRHELP="$HERE/error-dialog"
    if [ -x "$ERRHELP" ]; then
      "$ERRHELP" --title "BAR Launcher" --message "[${ERR_CODE:-unknown}] $MSG" --logfile "$LOG"
    else
      fail_dialog "$MSG"$'\n\n'"Details: $LOG"
    fi
    exit 1
  else
    # Update check failed on an already-working install (offline, CDN hiccup,
    # half-working train wifi): roll the tag metadata back so the OLD version
    # loads intact, play on existing content; the next launch retries.
    restore_rapid
    [ -n "$HPID" ] && { exec 4>&-; kill "$HPID" 2>/dev/null; }
    cleanup_fifo
    printf 'update check failed (code %s %s) — continuing on existing content\n' \
      "$RC" "${ERR_CODE:-}" >> "$LOG"
  fi
  trap - PIPE   # back to default before the engine exec below
fi

# The engine is the point of the whole exercise — if it is missing or cannot
# be exec'd the launcher must SAY so, not vanish with a silent exit 127.
if [ ! -x "$HERE/spring" ]; then
  fail_dialog "The game engine is missing from the app bundle. The download may have been interrupted — please re-download the game and drag it to Applications again."
  exit 1
fi
# execfail: a failed exec (kernel refused the binary: bad arch, quarantine,
# corrupt file) returns control here instead of silently killing the shell.
shopt -s execfail 2>/dev/null || true
# BAR_INFOLOG lets the engine's error dialog (Platform::MsgBox) attach the
# full this-session log to any fatal it shows.
SPRING_DATADIR="$RES" BAR_INFOLOG="$WRITEDIR/infolog.txt" \
BAR_PORT_VERSION="$PORT_VERSION" \
  exec "$HERE/spring" --write-dir "$WRITEDIR" --menu "$LOBBY_RAPID" "$@"
fail_dialog "The game engine could not be started (macOS refused to run it). Please re-download the game; if this keeps happening, report it with the log at: $WRITEDIR/first-run-download.log"
exit 1
