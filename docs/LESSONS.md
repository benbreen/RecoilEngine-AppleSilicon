# Lessons library (stable IDs — cite as LESSON-N)

Every painful or non-obvious finding becomes a numbered entry. Never renumber.

- **LESSON-1 — pr-downloader defaults point at the wrong universe.** BAR content
  does not live on the springrts rapid master. Without
  `PRD_RAPID_REPO_MASTER=https://repos-cdn.beyondallreason.dev/repos.gz` you get a
  cryptic "Error occurred while downloading: 1" after a successful-looking repos.gz
  fetch (it then name-searches springfiles and finds nothing). The engine's in-game
  downloader has a separate knob: springsettings `RapidTagResolutionOrder`.
- **LESSON-2 — the engine binary is not runnable bare on macOS.** The Zink/
  KosmicKrisp wiring is 100% environment-driven (`EGL_PLATFORM=surfaceless`,
  `VK_ICD_FILENAMES`/`VK_DRIVER_FILES` → kosmickrisp ICD json, `GALLIUM_DRIVER=zink`,
  `MESA_LOADER_DRIVER_OVERRIDE=zink`, `MESA_GL_VERSION_OVERRIDE=4.6`,
  `DYLD_FALLBACK_LIBRARY_PATH` for Zink's dlopen of `libvulkan.1.dylib`). Use
  `DYLD_FALLBACK_LIBRARY_PATH`, NOT `DYLD_LIBRARY_PATH` — forcing search order
  caused SIGBUS in prior work. Without the env you silently get llvmpipe (or no GL).
  Source of truth: ExaDev spring-launcher `src/macos_engine_env.js`.
- **LESSON-3 — sync-test hygiene.** `streflop-float-test <out>` appends `.bin` to
  the name you give it. The committed x86_64 SSE reference has 47,852 records; the
  NEON one 52,080 — compare against BOTH; "different test counts" against the SSE
  file is expected, mismatches are not. Local AppleClang arm64 build verified
  bit-exact 2026-07-12 (hash EA2881A4F127BF10).
- **LESSON-5 — lldb strips DYLD_* (SIP): set everything via
  `settings set target.env-vars K=V …` or the game silently loses its Vulkan stack
  under the debugger** ("MESA: error: ZINK: failed to load libvulkan.1.dylib").
  Offline symbolication works without rerunning: lldb disables ASLR by default, so
  a crash address can be fed to `image lookup -v -a <addr>` on the bare binary.
- **LESSON-6 — incremental engine rebuilds need the Mesa CPATH**
  (`export CPATH=deps/mesa-native/include`) or GlobalRendering.cpp fails on
  `EGL/egl.h`. Rebuild via `scripts/build-engine.sh` or export CPATH before bare
  ninja. configure-time CMake cache remembers libs, not header search paths.
- **LESSON-7 — the built-in frame capture (`SPRING_FRAME_CAPTURE`) stops after 1800
  swaps (~24 s)**; a "frozen clock" in late captures means the capture window ended,
  not that the sim paused. Extended with `SPRING_FRAME_CAPTURE_EVERY` /
  `SPRING_FRAME_CAPTURE_LIMIT` (0 = unlimited) in our tree.
- **LESSON-8 — Recoil's `LOG()` macro expands to a braceless `if` — never pair it
  with a bare `else`.** `if (cond) LOG(...); else foo();` compiles clean but `else`
  binds to the macro's inner if (dangling else): `foo()` becomes unreachable and the
  optimizer deletes it. Cost a full debug cycle (marker logs + lldb breakpoints +
  disassembly + `-E` preprocessing to find). Always brace both arms around LOG.
  Diagnostic ladder that found it: strings→binary has code; breakpoints→never hit;
  disassemble→call absent; preprocess→dangling else visible.
- **LESSON-9 — Water=2 ("dynamic") uses ARB assembly vertex programs that zink
  rejects** (`ARB/waterDyn.vp: invalid ARB vertex program option`), and the engine
  then persists Water=0 at exit (OF-7). BAR's "high water" is engine `Water=4`
  (BumpWater, GLSL) — use that. Audit remaining fixed-function/ARB-assembly render
  paths for the same zink incompatibility.
- **LESSON-11 — agent-blocking events are failure modes; see
  `AGENT_FAILURE_MODES.md`.** macOS GUI-modal dialogs (crash reporter, Gatekeeper),
  permission prompts (Accessibility for `osascript`, Screen Recording for
  `screencapture`), privileged-command denials (`sudo`/`launchctl`), and stuck
  audio/ports after `kill -9` all halt unattended runs. Prevention is baked into
  `scripts/preflight.sh` (suppress dialogs, kill stale procs) and
  `scripts/stop-spring.sh` (SIGTERM). Rule: suppress modals at the source, never
  GUI-script to dismiss them, SIGTERM not SIGKILL, and surface (don't retry)
  denied privileged actions.
- **LESSON-10 — looping/glitched audio is an ENGINE bug (audio device-change
  handling), NOT a `kill -9` artifact.** Original claim ("SIGKILL strands the audio
  device") was wrong — corrected after evidence: an AI-vs-AI run *self-crashed*
  (CrashHandler, no external signal) right after a burst of `SDL_AUDIODEVICEADDED`
  events (frame ~12271). `Sound::DeviceChanged` closes+reopens the device on each
  event; a device-list storm (virtual devices like BlackHole, capture devices) drives
  rapid close/reopen and something in that path faults — a stream playing when the
  device closes under it is the audible loop. Same path already logs "SDL failed to
  handle device change, reopening" at every boot. This is [[bar-audio-devicechange-crash]].
  Corollary on tooling: `kill -9` is a **fine, normal debugging tool**; don't avoid
  it. SIGTERM is only *preferred when you specifically want to test clean teardown*
  (so OpenAL/EGL run their dtors) — `scripts/stop-spring.sh` is for that case, not a
  ban on SIGKILL. Recover stuck audio by switching the macOS output device.
  (Separate, real: shutdown SIGABRT in ThreadPool `vector<thread>` dtor — a
  still-joinable thread at exit, POSIX-runs-dtors-Windows-skips — task #11.)
- **LESSON-12 — the fleet's FP semantics include gcc-only compiler flags; clang
  cannot always reproduce them via flags.** Recoil's top-level CMake adds
  `-fsingle-precision-constant -frounding-math` for GNU compilers only: every
  unsuffixed FP literal (`1.025`, `0.5`, …) in the ENTIRE engine — including
  streflop's bundled dbl-64 libm — is demoted to float on fleet builds. Clang
  rejects the flag ("not supported"), so a pure-clang mac build diverges wherever
  a demoted literal is inexact in float (found via asin/acos correction gates:
  ~45 ulp diffs; 8/9 other double families happened to be insensitive; flt-32
  fully insensitive). Fix: recompile the affected objects with homebrew gcc
  (honors the flag on arm64) and `ar`-swap them into the archive
  (`scripts/gcc-dbl64-swap.sh`). Two traps inside the trap: (a) externally
  touched objects make ninja's deps records stale — the next `ninja` run
  SILENTLY recompiles them with clang; swap after the full build, relink via
  `ninja -t commands <tgt> | tail -1`, and gate the result with a hash probe in
  the build script. (b) A statically-linked probe binary goes stale with the
  archive — recompile the probe before trusting its verdict.
- **LESSON-13 — "same source, same flags visible in the diff" is not enough:
  diff the full ninja command lines.** The asin divergence reproduced with
  identical sources, identical `-ffp-contract=off`, identical include order —
  the culprit flag was global (CMAKE_CXX_FLAGS), visible only in
  `ninja -t commands <obj>` output. When two builds of the same file disagree,
  put the two complete command lines side by side before theorizing about
  codegen.
- **LESSON-14 — demos without a game-over packet never end: cap replays by the
  header's gameTime.** If the recording player quit before the server's
  GameOver (common in public demos), spring-headless reaches the end of the
  demo stream and then SILENTLY simulates an empty world forever (observed
  437k+ frames on a 92k-frame demo — hours of wasted CPU and a "stuck" run
  that never desyncs and never exits). The sync verdict is already complete
  at that point: checksum comparison ends with the recorded stream. The demo
  header (gzip; magic "spring demofile") carries int32 gameTime at byte
  offset 312 (= 16 magic + 4 version + 4 headerSize + 256 versionString +
  16 gameID + 8 unixTime + 4 scriptSize + 4 demoStreamSize); real frame count
  = gameTime*30. replay-check.sh derives a wall-clock `timeout` cap from it.
  Related trap while diagnosing: don't trust api.bar-rts.com durationMs as
  sim length either — it disagreed with the header (3068s actual vs "51min"
  listed).
- **LESSON-15 — macOS Local Network privacy (TCC) blocks unsigned binaries'
  UDP to LAN/bridge addresses with errno 65 EHOSTUNREACH (looks like a routing
  bug, isn't).** Apple platform binaries (`nc`, `ping`) work from the same
  shell, so connectivity "tests fine" while the engine can't reach the same
  address — a freshly `cc`-compiled 10-line sendto repro is the discriminating
  test. Two TCC-exempt paths make VM multiplayer testing fully agent-runnable:
  (a) loopback is exempt and OrbStack forwards mac-localhost UDP ports into
  the VM, so the mac client JOINS a VM host via `hostip = 127.0.0.1`; (b)
  reply traffic on a remotely-initiated flow is permitted, so a mac HOST
  serving a VM-initiated connection works with no permission. For real LAN
  peers (B4 Windows box) there is no loopback path — the user must grant
  Local Network permission (System Settings → Privacy & Security → Local
  Network) to the terminal/launcher app first.
  **B4 resolution (2026-07-11): the grant path is a dead end under tmux —
  the durable fix is launching the engine inside an ssh-to-self login
  session.** Details: (a) processes under a tmux server never register in
  the Local Network list and never trigger the prompt (tmux daemonizes; TCC
  has no promptable responsible app), so the deny stays silent forever; (b)
  granting the terminal app (probe run in a plain non-tmux window → popup →
  Allow) does NOT cover tmux-descended processes; (c) per Apple TN3179,
  Local Network privacy does not apply inside SSH login sessions — so
  `ssh localhost <engine>` sends LAN UDP freely. Implemented as
  `MAC_VIA_SSH=1` in mp-test.sh (default for the win-hosts direction),
  using the bar_winbox keypair authorized for self-login with a
  `from="127.0.0.1,::1"` restriction (key unusable from the network; no
  winbox→mac attack path — the private key never leaves the mac).
- **LESSON-16 — the HOST drops a still-loading client after
  `InitialNetworkTimeout` (default 30s); a cold-cache first run on a fresh
  box takes far longer.** First B4 smoke: the Windows client connected
  instantly, then spent 99s on first-ever load (VFS checksumming the whole
  2.7GB pool + shader compiles) and the mac host logged "Spectator JoinSpec
  left the game: timeout" at exactly +30s. The client later finishes
  loading, finds itself disconnected, and BAR's autoquit widget exits — so
  the failure surfaces on the WRONG side (joiner "quit") unless you read
  the host log's timeout line. Fix: `InitialNetworkTimeout = 600` (+
  `NetworkTimeout = 300`) in the write-dir springsettings.cfg of BOTH
  hosts. B3 never hit this only because warm-cache loads were < 30s.
- **LESSON-17 — a multi-homed host replies from the wrong source IP; the
  client's connected UDP socket then silently drops every reply.** B4 raptors
  broke after a Windows Update: the winbox has THREE NICs all on
  192.168.1.0/24 (.81/.82/.175), the update reshuffled interface metrics so
  outbound routing to the mac switched from .81 to .82. The Spring SERVER
  binds 0.0.0.0 so it still RECEIVED the client's packets to .81 (logged
  "Connection established", client addr correct) — but its REPLIES left from
  the new primary .82. The mac client, having sent to .81, has a socket
  effectively bound to that peer and the kernel discards datagrams whose
  source is .82 → "server connection timeout", 0 bytes received of ~10k sent.
  Diagnostic that nailed it: an UNSIGNED UDP receiver in the mac ssh session
  (udprecv.c) got the winbox probe but printed `from 192.168.1.82` — the
  source-IP surprise. Two red herrings burned first: the re-enabled Windows
  firewall (LESSON: program-scoped allow rules did NOT fix it, because the
  block was never the firewall) and Local Network TCC (the unsigned receiver
  proved win→mac delivery was fine). FIX: force the intended NIC primary —
  `Set-NetIPInterface -InterfaceAlias Ethernet -InterfaceMetric 4` so
  `Find-NetRoute -RemoteIPAddress <mac>` returns .81 again; verify with the
  unsigned-receiver probe (source must match the IP the client dialed).
  General rule: on a multi-homed peer, the reply source IP must equal the
  hostip the client connects to; verify with a source-IP-printing probe, not
  just "a packet arrived."
- **LESSON-18 — GPU-timeline sync experiments can take down the whole
  MACHINE, not just the process: WindowServer shares the GPU.** Skipping
  KosmicKrisp's per-render-pass signal/wait event pair (KK_NO_PREGFX_SYNC
  experiment, kknosync-m7 2026-07-11) desynced the pre_gfx event protocol →
  GPU-side infinite wait → WindowServer userspace-watchdog timeouts
  (12:36+12:37 .spin reports) → hard reboot required. Spring's own watchdog
  fired 60s in, but a hung GPU cannot be recovered by killing the process.
  Protocol for any driver change that alters SYNC BEHAVIOR (vs. observational
  counters, which are safe): (a) commit all work first — the crash cost the
  cfg-restore trap and nearly the experiment diff; (b) understand the full
  event protocol (who waits on the skipped value?) before disabling anything;
  (c) first run = smallest scene + shortest cap, not the 2162-unit arena.
  Post-crash checklist: perf-bench's EXIT trap never ran → restore
  springsettings.cfg from the run's .cfg-backup (minus PerfProbe keys);
  data/infolog.txt still holds the crashed run's log — preserve it.
- **LESSON-19 — exonerate cheap hypotheses with a standalone microbenchmark
  and count operations BY CAUSE before patching driver behavior.** Phase C:
  three sync-structure theories (event-pair kick boundaries, queue-attached
  residency sets, cross-queue ping-pong) all died in one safe 100-line Metal
  microbench (~34µs/pass, flat in every mode) — where the earlier approach of
  patching the live driver had crashed the machine (LESSON-18) and produced a
  flat no-result. Then two observational driver counters (KK_PERF_STATS
  cause-split + KK_CB_TIMING timestamps) found the real cause in two bench
  runs: 94% of draws taking the primitive-restart unroll path. Order of
  operations that worked: (1) microbench the mechanism in isolation,
  (2) count causes in the real system, (3) only then change behavior — at
  the SOURCE (engine, one-line semantics-preserving gate), not the driver.
  Bonus gotcha: verify a rebuilt binary actually contains the patch
  (`strings binary | grep new-literal`) — the bench engine builds from
  `engine-2025.06.24/`, not `engine/`.
- **LESSON-4 — scripts need +x before backgrounding.** Direct invocation of a
  freshly written script in a background task dies with "permission denied" and the
  redirect-log stays empty; chmod in the same step as creation.
- **LESSON-20 — ambient thermals drift identical benches by ~5%; small effects
  need same-process A/Bs.** Warm-afternoon identical runs drifted 52.4→49.8
  (the size of most effects under test); in a cool room the same config
  spreads 0.1–0.3 fps over 10 runs. Method of record for <5% effects:
  runtime-config knobs + phased ABAB in ONE seeked process (BENCH_PHASES,
  de-trend by adjacent pairs, the "against-trend" pair is the conservative
  bound) + thermal stamps on every run (testkit/thermalstate). Cross-day
  absolute comparisons are not claims.
- **LESSON-21 — macOS QoS: raw std::thread / dispatch queues run at
  QOS_CLASS_DEFAULT (0x15) and children do NOT inherit promotion.** E-core
  eligible threads straggle and gate parallel-for groups. Promoting the
  engine's sync worker pool (USER_INITIATED) was worth ~+5% avg / +30%
  worst-case on the sim-bound cell — but promoting mesa's gdrv/zfq driver
  queues measured FLAT: promote only what measures, thread by thread.
- **LESSON-22 — rendered fps ≠ presented fps.** Skipping presents when the
  GPU runs behind (tried in the direct-present path) keeps rendered fps high
  while the glass goes stale (32k skips in one window). Present-path blocking
  is pipeline BACKPRESSURE, not waste; when touching it, count presents and
  drops, never just fps.
- **LESSON-23 — xctrace Metal System Trace is impractical on this workload at
  5K.** 70–150s windows produce 12–26GB traces whose save outlives generous
  caps or corrupts ("Document Missing Template Error"); --time-limit also
  kills the launched target. Three attempts, zero readable traces. GPU-side
  attribution beyond driver counters needs a human-attended Instruments
  session with a short manual window.
- **LESSON-24 — closed-negative ledger for the perf hunt (don't retry
  without new evidence):** ThinLTO flat (and streflop must be -fno-lto:
  Apple ld fails on late-loaded bitcode archive members); MESA_GLTHREAD
  flat-to-negative; CAMetalLayer.opaque no fps effect (capped and uncapped);
  driver-queue QoS flat; renderpass fragmentation self-resolved (r1 wins
  collapsed submits 10.3→0.5/frame — re-derive per-frame rates from CURRENT
  timestamps before sizing a lead from old counters).
