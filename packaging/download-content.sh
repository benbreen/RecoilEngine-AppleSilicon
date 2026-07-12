#!/bin/bash
# First-run content downloader for the BAR macOS app.
#
# Wraps pr-downloader against the OFFICIAL BAR content network (the same CDN
# the official launcher uses — endpoints from BYAR-Chobby dist_cfg): rapid
# game archives + Chobby lobby + engine maps into the user's write dir.
# Design per release plan §5:
#   - never writes inside the signed .app bundle;
#   - disk-space preflight (content is ~2-3 GB, checked before starting);
#   - resume/retry: pr-downloader's rapid pool is content-addressed, so a
#     re-run resumes where it stopped; we retry each item with backoff.
#
# STRUCTURED OUTPUT (stdout, one message per line) drives the launcher's
# progress window and the debug log:
#   @S <text>          stage / status line
#   @D <text>          detail line (host, tag, counts)
#   @P <int>           percent for the current item (0..100)
#   @I                 indeterminate step (unknown duration)
#   @E:<code> <text>   classified failure (see CODES below) — then exit nonzero
#   @DONE              all requested content present
# The full raw pr-downloader output is written to stderr (the launcher tees
# it to first-run-download.log) so any failure can be diagnosed after the fact.
#
# ERROR CODES (also the process exit code, so callers can branch):
#   2  usage        bad arguments
#   3  disk         not enough free space
#   4  launch       pr-downloader binary missing / would not start
#   5  network      could not reach the CDN (DNS/connat/TLS) — never got repos
#   6  tag          server reached, but the requested package tag was not found
#   7  content      tag resolved, but the archive/pool download failed/interrupted
# Usage: download-content.sh [--writedir DIR] [--full] [--map "Map Name"]...
set -uo pipefail   # NB not -e: we handle pr-downloader failures explicitly

APP_DIR=$(cd "$(dirname "$0")" && pwd)
PRD="${PRD:-$APP_DIR/pr-downloader}"
WRITEDIR="${HOME}/Library/Application Support/Beyond-All-Reason-mac"
MAPS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --writedir) WRITEDIR=$2; shift 2;;
    --map) MAPS+=("$2"); shift 2;;
    --full) FULL=1; shift;;
    *) echo "@E:usage unknown argument: $1"; exit 2;;
  esac
done

# machine-readable status helpers (stdout); raw diagnostics go to stderr
say()   { printf '@S %s\n' "$*"; }
detail(){ printf '@D %s\n' "$*"; }
pulse() { printf '@I\n'; }
emit_err() { printf '@E:%s %s\n' "$1" "$2"; }   # emit_err <code> <text>

if [ ! -x "$PRD" ]; then
  emit_err launch "The downloader component is missing from the app bundle. Please re-download and reinstall the game."
  exit 4
fi
mkdir -p "$WRITEDIR"

# Official BAR content network (BYAR-Chobby dist_cfg/config.json values).
export PRD_RAPID_REPO_MASTER="https://repos-cdn.beyondallreason.dev/repos.gz"
export PRD_HTTP_SEARCH_URL="https://files-cdn.beyondallreason.dev/find"
# NB SPRING_DATADIR must NOT be set for pr-downloader (it shares the engine's
# data-dir resolution and would treat a read-only dir as its write target).
# NB pr-downloader sends its standard "pr-downloader/<version>" UA; it reads no
# UA env var — a mac-identifying suffix is an upstream candidate (see docs).

# ---- disk preflight -----------------------------------------------------------
say "Checking free disk space"
need_kb=$((4 * 1024 * 1024))   # ~4 GB (content ~2-3 GB + headroom)
free_kb=$(df -k "$WRITEDIR" | awk 'NR==2 {print $4}')
if [ "${free_kb:-0}" -lt "$need_kb" ]; then
  emit_err disk "Not enough free disk space: about 4 GB is needed, but only $((free_kb/1024/1024)) GB is free where game data is stored."
  exit 3
fi

# ---- one download item, with staged progress + classified errors --------------
# fetch <label> <human-name> <prd-args...>
fetch() {
  local label=$1 human=$2; shift 2
  local attempt rc raw reached_server resolved_tag
  raw=$(mktemp)
  for attempt in 1 2 3; do
    if [ "$attempt" -eq 1 ]; then say "Contacting content servers…"
    else say "Retrying (attempt $attempt of 3)…"; fi
    pulse

    # stream pr-downloader; classify stages live; keep full output in $raw.
    # Progress % is suppressed until the archive download actually starts
    # ([Download]) so the bar reflects the real content, not the tiny repos
    # fetch (which otherwise flashes to 100% then resets).
    # tr: pr-downloader separates progress updates with \r (no newline) when
    # piped — without translation the whole bar arrives as one "line" and the
    # window gets only 1-2 percent updates for the entire download
    "$PRD" --filesystem-writepath "$WRITEDIR" "$@" 2>&1 | tr '\r' '\n' | tee "$raw" | \
    { in_download=0; started=0
      while IFS= read -r line; do
        case "$line" in
          *"Found "*" repos in "*) printf '@S %s\n' "Server reached — resolving ${human}…" ;;
          *"[Download]"*)          in_download=1; printf '@S %s\n' "Downloading ${human}…" ;;
          *"[Progress]"*)
            [ "$in_download" -eq 1 ] || continue
            pct=$(printf '%s' "$line" | sed -n 's/.*\[Progress\][^0-9]*\([0-9][0-9]*\)%.*/\1/p')
            [ -n "$pct" ] || continue
            # a stale 100% from the resolve fetch can trail into the gated
            # stream — don't let the bar flash full before the pool starts
            if [ "$started" -eq 0 ]; then
              [ "$pct" -ge 100 ] && continue
              started=1
            fi
            printf '@P %s\n' "$pct" ;;
        esac
      done; }
    rc=${PIPESTATUS[0]}

    [ "$rc" -eq 0 ] && { rm -f "$raw"; return 0; }

    grep -q "Found .* repos in " "$raw" && reached_server=1 || reached_server=0
    grep -q "\[Download\]" "$raw" && resolved_tag=1 || resolved_tag=0
    printf '=== %s attempt %d rc=%d (server=%d tag=%d) ===\n' "$label" "$attempt" "$rc" "$reached_server" "$resolved_tag" >&2
    cat "$raw" >&2

    # rc >= 128 means the downloader was killed by a SIGNAL, not a network
    # failure. SIGKILL (137) with no server contact is almost always macOS
    # Gatekeeper killing an unsigned/quarantined nested binary — i.e. the app
    # is not fully installed / not notarized, NOT the user's connection.
    # Deterministic: don't retry, classify immediately.
    if [ "$rc" -ge 128 ]; then
      sig=$((rc - 128))
      emit_err install "The downloader was stopped by macOS (signal $sig) before it could run. This usually means the app is not fully installed or verified: move Beyond All Reason into your Applications folder and open it from there. If you just downloaded it, re-download and try again. (Not an internet problem.)"
      rm -f "$raw"; return 8
    fi

    # A tag-not-found is DETERMINISTIC — do not waste time retrying it.
    if [ "$reached_server" -eq 1 ] && [ "$resolved_tag" -eq 0 ]; then
      emit_err tag "The '$human' package was not found on the content server (looked up '$*'). This build may be pointed at a package name the server no longer publishes — please check for an updated game version."
      rm -f "$raw"; return 6
    fi

    # network / content failures may be transient — retry with backoff
    if [ "$attempt" -lt 3 ]; then
      printf '@D %s\n' "Attempt $attempt failed — retrying in $((attempt*5))s"
      sleep $((attempt * 5)); continue
    fi

    if [ "$reached_server" -eq 0 ]; then
      if grep -qiE "resolve host|could not resolve|couldn't resolve|name or service|timed out|timeout|connection refused|could not connect|ssl|certificate" "$raw"; then
        emit_err network "Could not reach the content servers. Check your internet connection, then start the game again."
      else
        emit_err network "Could not download the server file list (no connection to the content network)."
      fi
      rm -f "$raw"; return 5
    else
      emit_err content "The '$human' download did not finish (the connection dropped or a file failed verification). Please start the game again to resume."
      rm -f "$raw"; return 7
    fi
  done
}

# Default scope: lobby + game. The lobby CANNOT fetch the game itself on this
# port — BYAR-Chobby's in-lobby game download goes through the spring-launcher
# wrapper protocol (shows as a literal "BAR $VERSION" entry that fails), which
# this launcher does not implement. So the game archive must be fetched here,
# and the launcher re-runs this check every launch (rapid is content-addressed:
# a current install no-ops in seconds — same as the official launcher's update
# check). Maps still download fine in-lobby (engine downloader path).
# BAR_CONTENT_SCOPE=lobby restores the lobby-only scope (build smokes).
fetch "lobby" "game lobby" --download-game byar-chobby:test || exit $?
if [ "${BAR_CONTENT_SCOPE:-full}" != "lobby" ]; then
  fetch "game" "game content" --download-game byar:stable || exit $?
fi
for m in "${MAPS[@]:-}"; do
  [ -n "$m" ] && { fetch "map:$m" "map $m" --download-map "$m" || exit $?; }
done

printf '@DONE\n'
printf 'CONTENT_OK writedir=%s\n' "$WRITEDIR" >&2
