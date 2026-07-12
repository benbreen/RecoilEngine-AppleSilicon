#!/bin/bash
# message-check-test.sh — local harness for the remote-message helper.
# Compiles message-check, then drives it with --dry-run (simulates pressing
# each message's DEFAULT button; no windows) against file:// fixtures to assert
# version targeting, ordering, once/suppression tracking, forced-quit, and
# fail-open. No network, no GUI. Usage: packaging/test/message-check-test.sh
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/message-check"
swiftc -O -o "$BIN" "$PKG/message-check.swift" || { echo "FATAL: compile failed"; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass+1)); printf "  ok   %s\n" "$1"; }
bad()  { fail=$((fail+1)); printf "  FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "       %s\n" "$2"; }
run()  { # run <config> <version> <seen-file>  -> stdout=decisions, sets RC
  "$BIN" --config-url "file://$1" --app-version "$2" --seen-file "$3" --dry-run 2>/dev/null; RC=$?; }

# ---------- fixture: targeting + ordering (continue-default so nothing quits) -
cat > "$WORK/targeting.jsonc" <<'JSON'
{
  // targeting + ordering fixture
  "schema": 1,
  "messages": [
    { "id": "m-ge02",  "date": "2026-03-02", "target": {"op":"ge","version":"0.2"}, "title":"ge", "body":"<p>ge</p>", "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] },
    { "id": "m-all",   "date": "2026-01-01", "target": {"op":"all"},                "title":"all","body":"<p>all</p>","frequency":"once",   "buttons":[{"label":"OK","action":"continue","default":true}] },
    { "id": "m-eq015", "date": "2026-05-05", "target": {"op":"eq","version":"0.15"},"title":"eq", "body":"<p>eq</p>", "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] },
    { "id": "m-lt02",  "date": "2026-02-01", "target": {"op":"lt","version":"0.2"}, "title":"lt", "body":"<p>lt</p>", "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] }
  ]
}
JSON

shown() { run "$WORK/targeting.jsonc" "$1" "$WORK/none-$RANDOM" | awk '/^SHOW/{sub(/^SHOW id=/,"");print $1}' | paste -sd, -; }

echo "== targeting & ordering =="
[ "$(shown 0.1)"  = "m-all,m-lt02" ]         && ok "v0.1 -> all,lt (ordered by date)"   || bad "v0.1" "got: $(shown 0.1)"
[ "$(shown 0.2)"  = "m-all,m-ge02" ]         && ok "v0.2 -> all,ge"                     || bad "v0.2" "got: $(shown 0.2)"
[ "$(shown 0.11)" = "m-all,m-ge02" ]         && ok "v0.11 -> all,ge (0.11 > 0.2)"       || bad "v0.11" "got: $(shown 0.11)"
[ "$(shown 0.15)" = "m-all,m-ge02,m-eq015" ] && ok "v0.15 -> all,ge,eq"                 || bad "v0.15" "got: $(shown 0.15)"

# ---------- seen tracking: once vs always ------------------------------------
echo "== once / always tracking =="
SEEN="$WORK/seen1"; : > "$SEEN"
"$BIN" --config-url "file://$WORK/targeting.jsonc" --app-version 0.1 --seen-file "$SEEN" --dry-run >/dev/null 2>&1   # first run marks m-all (once) seen
second=$("$BIN" --config-url "file://$WORK/targeting.jsonc" --app-version 0.1 --seen-file "$SEEN" --dry-run 2>/dev/null | awk '/^SHOW/{sub(/^SHOW id=/,"");print $1}' | paste -sd, -)
[ "$second" = "m-lt02" ] && ok "2nd run: 'once' m-all suppressed, 'always' m-lt02 repeats" || bad "seen tracking" "got: $second"

# ---------- suppression checkbox default --------------------------------------
echo "== suppression checkbox =="
cat > "$WORK/supp.jsonc" <<'JSON'
{ "schema":1, "messages":[
  { "id":"supp-on",  "target":{"op":"all"}, "title":"on",  "body":"<p>x</p>", "suppressible":true, "suppressDefault":true,  "buttons":[{"label":"OK","action":"continue","default":true}] },
  { "id":"supp-off", "target":{"op":"all"}, "title":"off", "body":"<p>x</p>", "suppressible":true, "suppressDefault":false, "buttons":[{"label":"OK","action":"continue","default":true}] }
]}
JSON
S="$WORK/seen2"; : > "$S"
"$BIN" --config-url "file://$WORK/supp.jsonc" --app-version 1.0 --seen-file "$S" --dry-run >/dev/null 2>&1
after=$("$BIN" --config-url "file://$WORK/supp.jsonc" --app-version 1.0 --seen-file "$S" --dry-run 2>/dev/null | awk '/^SHOW/{sub(/^SHOW id=/,"");print $1}' | paste -sd, -)
[ "$after" = "supp-off" ] && ok "default-checked box suppresses; default-unchecked keeps showing" || bad "suppression" "got: $after"

# ---------- server control wins: forced message ignores prior suppression ----
echo "== server control wins =="
S3="$WORK/seen3"; : > "$S3"
# v1 of the message: suppressible, default-checked -> user suppresses it
cat > "$WORK/flip-v1.jsonc" <<'JSON'
{ "schema":1, "messages":[
  { "id":"flip", "target":{"op":"all"}, "title":"note", "body":"<p>x</p>", "suppressible":true, "suppressDefault":true, "buttons":[{"label":"OK","action":"continue","default":true}] }
]}
JSON
"$BIN" --config-url "file://$WORK/flip-v1.jsonc" --app-version 1.0 --seen-file "$S3" --dry-run >/dev/null 2>&1   # suppresses "flip"
gone=$("$BIN" --config-url "file://$WORK/flip-v1.jsonc" --app-version 1.0 --seen-file "$S3" --dry-run 2>/dev/null | grep -c '^SHOW')
[ "$gone" = 0 ] && ok "suppressed message no longer shows" || bad "suppress" "shown=$gone"
# author flips SAME id to non-suppressible/forced -> must re-show despite seen
cat > "$WORK/flip-v2.jsonc" <<'JSON'
{ "schema":1, "messages":[
  { "id":"flip", "target":{"op":"all"}, "title":"note", "body":"<p>x</p>", "suppressible":false, "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] }
]}
JSON
back=$("$BIN" --config-url "file://$WORK/flip-v2.jsonc" --app-version 1.0 --seen-file "$S3" --dry-run 2>/dev/null | grep -c '^SHOW')
[ "$back" = 1 ] && ok "forced ('always') message re-shows despite prior suppression" || bad "server wins" "shown=$back"

# ---------- forced quit (kill-switch) ----------------------------------------
echo "== forced quit =="
cat > "$WORK/kill.jsonc" <<'JSON'
{ "schema":1, "messages":[
  { "id":"bad", "target":{"op":"eq","version":"0.15"}, "title":"bad", "body":"<p>bad</p>", "frequency":"always",
    "buttons":[{"label":"Download","action":"open-url","url":"https://example.com","then":"quit","default":true},{"label":"Quit","action":"quit"}] }
]}
JSON
run "$WORK/kill.jsonc" 0.15 "$WORK/none-a" >/dev/null; [ "$RC" = 2 ] && ok "bad build -> exit 2 (quit)" || bad "kill exit" "rc=$RC"
run "$WORK/kill.jsonc" 0.2  "$WORK/none-b" >/dev/null; [ "$RC" = 0 ] && ok "unaffected version -> exit 0 (continue)" || bad "kill miss" "rc=$RC"

# ---------- version range ----------------------------------------------------
echo "== version range =="
cat > "$WORK/range.jsonc" <<'JSON'
{ "schema":1, "messages":[
  { "id":"r-incl", "target":{"op":"range","min":"1.1","max":"2.3"}, "title":"r", "body":"<p>r</p>", "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] },
  { "id":"r-excl", "target":{"op":"range","min":"1.1","max":"2.3","maxInclusive":false}, "title":"e", "body":"<p>e</p>", "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] }
]}
JSON
rshow() { "$BIN" --config-url "file://$WORK/range.jsonc" --app-version "$1" --seen-file "$WORK/nr-$RANDOM" --dry-run 2>/dev/null | awk '/^SHOW/{sub(/^SHOW id=/,"");print $1}' | paste -sd, -; }
[ "$(rshow 1.0)" = "" ]              && ok "1.0 below range -> none"        || bad "range 1.0" "got: $(rshow 1.0)"
[ "$(rshow 1.1)" = "r-incl,r-excl" ] && ok "1.1 min bound inclusive"        || bad "range 1.1" "got: $(rshow 1.1)"
[ "$(rshow 2.3)" = "r-incl" ]        && ok "2.3 max: inclusive shows, exclusive hides" || bad "range 2.3" "got: $(rshow 2.3)"
[ "$(rshow 2.4)" = "" ]              && ok "2.4 above range -> none"        || bad "range 2.4" "got: $(rshow 2.4)"

# ---------- multi-line body (array of lines) ---------------------------------
echo "== multi-line body =="
cat > "$WORK/multiline.jsonc" <<'JSON'
{ "schema":1, "messages":[
  { "id":"ml", "target":{"op":"all"}, "title":"ml", "body":["<p>line one ","and <b>line two</b></p>"], "frequency":"always", "buttons":[{"label":"OK","action":"continue","default":true}] }
]}
JSON
mshow=$("$BIN" --config-url "file://$WORK/multiline.jsonc" --app-version 1.0 --seen-file "$WORK/nm" --dry-run 2>/dev/null | grep -c '^SHOW')
[ "$mshow" = 1 ] && ok "array-of-lines body decodes and applies" || bad "multiline body" "shown=$mshow"

# ---------- fail-open ---------------------------------------------------------
echo "== fail-open =="
run "$WORK/does-not-exist.json" 0.1 "$WORK/none-c" >/dev/null; [ "$RC" = 0 ] && ok "missing config -> exit 0" || bad "missing" "rc=$RC"
printf '{ this is not json' > "$WORK/malformed.json"
run "$WORK/malformed.json" 0.1 "$WORK/none-d" >/dev/null; [ "$RC" = 0 ] && ok "malformed config -> exit 0" || bad "malformed" "rc=$RC"
printf '{ "schema": 2, "messages": [] }' > "$WORK/wrongschema.json"
run "$WORK/wrongschema.json" 0.1 "$WORK/none-e" >/dev/null; [ "$RC" = 0 ] && ok "unknown schema -> exit 0" || bad "schema" "rc=$RC"

# ---------- assembler + shipped example ---------------------------------------
echo "== assembler + shipped example =="
if python3 "$PKG/../message-config/assemble.py" --check >/dev/null 2>&1; then ok "assemble.py validates messages/*.jsonc"; else bad "assemble validate"; fi
python3 "$PKG/../message-config/assemble.py" >/dev/null 2>&1
ex=$("$BIN" --config-url "file://$PKG/../message-config/messages.json" --app-version 0.1 --seen-file "$WORK/none-g" --dry-run 2>/dev/null | awk '/^SHOW/{c++} END{print c+0}')
[ "$ex" -ge 1 ] && ok "assembled messages.json parses and targets v0.1 ($ex message(s))" || bad "example parse" "shown=$ex"

# ---------- all comparison operators -----------------------------------------
echo "== comparison operators =="
cat > "$WORK/ops.jsonc" <<'JSON'
{ "schema":1, "messages":[
  {"id":"eq","target":{"op":"eq","version":"2.0"},"title":"","body":"<p/>","frequency":"always","buttons":[{"label":"OK","action":"continue","default":true}]},
  {"id":"ne","target":{"op":"ne","version":"2.0"},"title":"","body":"<p/>","frequency":"always","buttons":[{"label":"OK","action":"continue","default":true}]},
  {"id":"le","target":{"op":"le","version":"2.0"},"title":"","body":"<p/>","frequency":"always","buttons":[{"label":"OK","action":"continue","default":true}]},
  {"id":"ge","target":{"op":"ge","version":"2.0"},"title":"","body":"<p/>","frequency":"always","buttons":[{"label":"OK","action":"continue","default":true}]},
  {"id":"gt","target":{"op":"gt","version":"2.0"},"title":"","body":"<p/>","frequency":"always","buttons":[{"label":"OK","action":"continue","default":true}]},
  {"id":"lt","target":{"op":"lt","version":"2.0"},"title":"","body":"<p/>","frequency":"always","buttons":[{"label":"OK","action":"continue","default":true}]}
]}
JSON
ops() { "$BIN" --config-url "file://$WORK/ops.jsonc" --app-version "$1" --seen-file "$WORK/no-$RANDOM" --dry-run 2>/dev/null | awk '/^SHOW/{sub(/^SHOW id=/,"");print $1}' | sort | paste -sd, -; }
[ "$(ops 2.0)" = "eq,ge,le" ] && ok "v2.0 -> eq,le,ge"  || bad "ops 2.0" "$(ops 2.0)"
[ "$(ops 1.9)" = "le,lt,ne" ] && ok "v1.9 -> ne,lt,le"  || bad "ops 1.9" "$(ops 1.9)"
[ "$(ops 2.1)" = "ge,gt,ne" ] && ok "v2.1 -> ne,gt,ge"  || bad "ops 2.1" "$(ops 2.1)"

# ---------- button actions + config-specified default ------------------------
echo "== button actions & default selection =="
mk() { printf '{ "schema":1, "messages":[{"id":"b","target":{"op":"all"},"title":"","body":"<p/>","frequency":"always","buttons":%s}]}' "$1" > "$WORK/b.jsonc"; }
ec() { "$BIN" --config-url "file://$WORK/b.jsonc" --app-version 1 --seen-file "$WORK/nb-$RANDOM" --dry-run >/dev/null 2>&1; echo $?; }
mk '[{"label":"Open","action":"open-url","url":"https://x","then":"continue","default":true},{"label":"Q","action":"quit"}]'
[ "$(ec)" = 0 ] && ok "default open-url then=continue -> exit 0" || bad "openurl-cont"
mk '[{"label":"Open","action":"open-url","url":"https://x","then":"quit","default":true},{"label":"Stay","action":"continue"}]'
[ "$(ec)" = 2 ] && ok "default open-url then=quit -> exit 2" || bad "openurl-quit"
mk '[{"label":"Stay","action":"continue"},{"label":"Quit","action":"quit","default":true}]'
[ "$(ec)" = 2 ] && ok "config default=2nd(quit) overrides first-button default -> exit 2" || bad "default2"
printf '{ "schema":1, "messages":[{"id":"b","target":{"op":"all"},"title":"","body":"<p/>","frequency":"always"}]}' > "$WORK/b.jsonc"
o=$("$BIN" --config-url "file://$WORK/b.jsonc" --app-version 1 --seen-file "$WORK/nb0" --dry-run 2>/dev/null)
{ echo "$o" | grep -q 'default=OK' && "$BIN" --config-url "file://$WORK/b.jsonc" --app-version 1 --seen-file "$WORK/nb0b" --dry-run >/dev/null 2>&1; } \
  && ok "no buttons -> synthesised OK/continue" || bad "empty buttons" "$o"

# ---------- JSONC comment stripping is url-safe ------------------------------
echo "== JSONC url-safety =="
cat > "$WORK/jc.jsonc" <<'JSON'
{
  // a full-line comment, must be stripped
  "schema": 1,
  "messages": [
    { "id":"u", "target":{"op":"all"}, "title":"t", "body":"<a href='https://example.com/x'>l</a>", "frequency":"always",
      "buttons":[{"label":"Go","action":"open-url","url":"https://example.com/p","then":"continue","default":true}] }
  ]
}
JSON
[ "$("$BIN" --config-url "file://$WORK/jc.jsonc" --app-version 1 --seen-file "$WORK/nj" --dry-run 2>/dev/null | grep -c '^SHOW')" = 1 ] \
  && ok "full-line // stripped; https:// inside values preserved" || bad "jsonc url"

# ---------- assemble.py validation -------------------------------------------
echo "== assemble.py validation =="
AT="$WORK/at"; mkdir -p "$AT/messages"; cp "$PKG/../message-config/assemble.py" "$AT/"
echo '{"id":"a","target":{"op":"all"},"title":"t","body":"<p/>"}' > "$AT/messages/a.jsonc"
echo '{"id":"a","target":{"op":"all"},"title":"t","body":"<p/>"}' > "$AT/messages/b.jsonc"
python3 "$AT/assemble.py" --check >/dev/null 2>&1; [ $? = 1 ] && ok "duplicate id rejected" || bad "dup id"
rm "$AT/messages/b.jsonc"; printf '{ not json' > "$AT/messages/c.jsonc"
python3 "$AT/assemble.py" --check >/dev/null 2>&1; [ $? = 1 ] && ok "invalid JSON rejected" || bad "bad json"
rm "$AT/messages/c.jsonc"
python3 "$AT/assemble.py" --check >/dev/null 2>&1 && ok "clean set validates" || bad "clean validate"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
