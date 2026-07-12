# Agent-autonomy failure modes (BAR macOS port)

**Premise:** anything that stops an agent from *noticing* a problem, or forces it to
*stop and wait for a human*, is a failure mode — as much a defect as a crash. Catalog
them here, note the workaround, and prefer engineering them out (preventive script
changes, diagnostics) over "remember to be careful."

Two axes:
- **Observability failures** — the problem happened but the agent couldn't see it
  (silent fallbacks, blind crash handlers, logging that lies, tools that stop quietly).
- **Autonomy blockers** — the agent saw the problem but couldn't act without a human
  (GUI-modal dialogs, privileged-command denials, permission prompts, hangs).

---

## Autonomy blockers (need a human → break unattended runs)

| # | Blocker | Why it stops the agent | Prevention / workaround |
|---|---|---|---|
| AB-1 | **macOS crash-reporter dialog** ("spring quit unexpectedly", Reopen/Ignore) | GUI modal; nothing proceeds until a human clicks | **Pre-set** `defaults write com.apple.CrashReporter DialogType none` (done). Reports still land in `~/Library/Logs/DiagnosticReports/*.ips`. Preflight checks it (`scripts/preflight.sh`). |
| AB-2 | **Gatekeeper "app is damaged"** on ad-hoc-signed bundles | GUI modal on launch | `xattr -dr com.apple.quarantine <app>` before launch (cask does this in postflight). |
| AB-3 | **Accessibility permission prompt** when GUI-scripting (`osascript … keystroke/click`) over SSH | Prompt names `sshd-keygen-wrapper`; needs a human grant, and grants broad control | **Don't GUI-script.** Kill processes with signals, suppress dialogs at the source (AB-1). Never automate a click. |
| AB-4 | **Privileged commands** (`sudo killall coreaudiod`, `launchctl unload`) | Denied by the permission classifier; needs a human | Prefer unprivileged alternatives (switch audio device; SIGTERM not SIGKILL so no cleanup is skipped). Surface to the user rather than retrying. |
| AB-5 | **Screen Recording permission** for `screencapture` | Denied → empty image; can't see the live screen | Use the engine's `SPRING_FRAME_CAPTURE` → `raw2png.py` → read PNG. Self-contained, no permission. (This is the standard visual-verification loop now.) |
| AB-6 | **Stuck/looping audio** (LESSON-10) | Audible glitch loop; a human notices it, the agent may not | It's a symptom of the engine audio-devicechange bug ([[bar-audio-devicechange-crash]]), *not* of how the process was killed. Recover by switching the macOS output device. `kill -9` is fine; SIGTERM only matters when testing clean teardown. |
| AB-7 | **Port / device held by a leftover process** (`bind: Address already in use`; also stale audio/GL state) | A previous run's straggler makes the next run fatal or flaky at startup | Reaper (`scripts/reap.sh`) + preflight stop stale `spring`/`spring-headless` before launch; check periodically during long unattended work, not just at launch. |
| AB-8 | **Blocking `sleep` in the harness** ("Blocked: sleep 25 …") | Long foreground sleeps are refused; a naive wait stalls the turn | Background + `until <cond>; do sleep N; done`, or Monitor. Never chain sleeps. |
| AB-9 | **Docker credential helper needs the locked keychain** over SSH ("keychain cannot be accessed…") | Any `docker pull`, even anonymous, fails via the osxkeychain credsStore | `DOCKER_CONFIG=<dir-with-empty-config.json>` for anonymous pulls (`.docker-anon/`); no keychain, no human. |
| AB-10 | **Local Network TCC under tmux: silent deny, no prompt, no Settings entry** (LESSON-15/16 era) | Processes under a tmux server have no promptable responsible app — outbound LAN UDP gets errno-65 forever, nothing appears in System Settings to toggle, and granting the terminal app doesn't cover tmux descendants | Launch the network-using binary inside an ssh-to-self login session (TN3179 exempts SSH sessions): `mp-test.sh` `MAC_VIA_SSH=1`. One-time setup: user authorizes `~/.ssh/bar_winbox.pub` in their own `authorized_keys` with `from="127.0.0.1,::1"`. |
| AB-11 | **Permission classifier denies self-persistence** (appending to `~/.ssh/authorized_keys`, even via a staged script) | Denied action; agent cannot self-authorize — correctly so | Stage the exact data (e.g. `testkit/keyline.txt`) and have the user run the one short append via the `!` prompt prefix; don't retry the denied action. |
| AB-12 | **Windows Update servicing restarts sshd mid-run → conpty kills the whole session process tree** (burned: B4 raptors host died at f=44,682; NO crash event — infolog just stops mid-write; sshd log shows "Received signal 8; terminating" + WU KB install minutes later) | Remote engine dies with no fault signature; looks like an engine crash; RADAR leak telemetry red-herrings the diagnosis | During test campaigns: `Stop-Service wuauserv,UsoSvc; Set-Service … Disabled` on the box (**re-enable after: Set-Service wuauserv -StartupType Manual; Set-Service UsoSvc -StartupType Manual**). Diagnosis recipe: engine infolog truncated mid-write + no Application Error event ⇒ external kill; check `OpenSSH/Operational` for sshd restarts, System log for the trigger. Hardening option if it recurs: launch the remote engine DETACHED (Start-Process, log to file, fetch after) so sshd restarts can't kill it. |

## Observability failures (problem is invisible → agent proceeds wrongly)

| # | Failure | How it hides | Detection |
|---|---|---|---|
| OF-1 | **Silent renderer fallback** to llvmpipe/software | Correct picture, single-digit FPS; green exit code | Assert the infolog renderer string is `…MESA_KOSMICKRISP`, GL `4.6 (Compatibility Profile)` — not llvmpipe (principles §6). |
| OF-2 | **Blind engine CrashHandler on macOS** | libunwind prints only `_sigtramp` through signal frames — useless | Real backtrace via lldb (`target.env-vars`, LESSON-5) or the `.ips` diagnostic report; offline symbolication with `image lookup -v -a <addr>`. |
| OF-3 | **`LOG()` dangling-else compiles code out** (LESSON-8) | No error, no warning; the call just vanishes | Brace both arms around any `LOG()`. Confirm via disassembly / `-E` when a call "should run but doesn't." |
| OF-4 | **Silent Lua handler failure** (LuaIntro `KillLua()` with no log) | Feature silently absent; downstream breaks far away | Add a warning at every silent early-return (did for LuaIntro); treat "feature missing, no error" as an observability bug to fix. |
| OF-5 | **Subsystem returns false without detail** (atlas `Finalize()`) | One generic error line, real cause (size/pages/count) hidden | Log the state at the failure site (did for TextureAtlas). |
| OF-6 | **Observation tool stops quietly** (frame capture halts at 1800 swaps, LESSON-7) | Late captures look "frozen" — reads as a sim hang, isn't | Know the tool's limits; made interval/limit configurable. |
| OF-7 | **Config silently rewritten on exit** (Water=4 → 0 after ARB reject) | Next run differs with no signal | Set config with the engine stopped; diff `springsettings.cfg` when behavior drifts between runs. |
| OF-8 | **Stale binary / dependency** (GeneralsX lesson, inherited) | Build "succeeds" but ships old artifact | `file`/`otool -L`/`strings`/`lipo -info` on the artifact, not the exit code. |

---

## Standing rules for autonomous runs (derived from the above)

1. **Suppress GUI modals at the source before running**, don't dismiss them after
   (dismissal needs Accessibility = a human). Preflight enforces AB-1/AB-2.
2. **Reap stragglers regularly, not just at launch — on EVERY machine involved**
   (user directive 2026-07-11: mac AND winbox). A leftover engine holds the
   host socket and audio/GL state; a periodic check during long unattended work
   (`scripts/reap.sh` mac; `Get-Process spring-headless` via ssh winbox) catches
   self-crashed or orphaned instances before the next run trips over them.
   mp-test.sh does both automatically pre-launch (preflight + remote_reap).
   SIGTERM first (lets OpenAL/EGL close); `kill -9` is a fine
   fallback for a genuine hang — it is not itself a hazard.
   **NB winbox clock skew**: the box shows GMT with no DST applied — its
   local timestamps (Get-Process StartTime, log times) read 1h BEHIND the
   mac in summer. A "started an hour ago" process may be brand new — compare
   against `ssh winbox Get-Date`, not the mac clock, before calling it an
   orphan (burned once, 2026-07-11).
3. **No GUI scripting, ever** — it trades one blocker for a worse one (AB-3).
4. **Every silent early-return / fallback gets a log line** — an unobserved failure
   is a bug even when the code is "correct" (OF-1, OF-4, OF-5).
5. **Verify artifacts and runtime strings, not exit codes** (OF-1, OF-8).
6. **When a privileged command is the only fix, stop and tell the user** — don't
   loop on a denied action (AB-4).
