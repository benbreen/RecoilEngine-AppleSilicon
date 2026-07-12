# BAR → macOS Porting Principles

Guidelines for anyone (human or agent) working on the Beyond All Reason macOS port.
Modeled on the porting principles of the C&C Generals Apple port
(https://github.com/ammaarreshi/Generals-Mac-iOS-iPad — `docs/port/PORTING_PATTERNS.md`,
`PORTING_PLAYBOOK.md`; built on https://github.com/fbraz3/GeneralsX) but adapted to what BAR actually is: a **lockstep-deterministic
multiplayer RTS** whose game content is Lua running on the **Recoil engine** (C++23,
fork of Spring 105). That changes the priorities completely compared to a single-player
port: determinism is not a nice-to-have here, it is the product.

---

## 0. What "BAR" is (the four-repo reality)

| Piece | Repo | Language | Ports? |
|---|---|---|---|
| Engine (sim, render, net, VFS, Lua host) | `beyond-all-reason/RecoilEngine` | C++23 | **This is the port.** |
| Game (units, mechanics, UI, AI config) | `beyond-all-reason/Beyond-All-Reason` | Lua | Never modified. Downloaded at runtime, checksummed. |
| Lobby (production) | `beyond-all-reason/BYAR-Chobby` | Lua (runs inside engine LuaMenu) | Minor launcher-level work only. |
| Lobby (next-gen) + launcher | `bar-lobby` | Electron/TS | Packaging-level work only. |

The game content is platform-independent by construction and **version-checksummed**:
every player in a match runs byte-identical Lua. Therefore *all* porting work lands in
the engine and the delivery/packaging layer. If a fix seems to require changing game
Lua, that is an engine bug being worked around in the wrong layer — stop.

## 1. Golden rules

1. **Stand on the ecosystem, stay mergeable.** The ExaDev fork (June 2026) already
   achieves working macOS multiplayer; upstream PRs #2819 (merged — ARM64 deterministic
   FP), #2820 (macOS platform) and #2991 (Zink→KosmicKrisp graphics) carry the core.
   History lesson from the springrts era and repeated by Recoil maintainers: **every
   unmergeable macOS mega-fork has died** when its single maintainer left. Work as a
   thin, documented patch set on top of upstream master; upstream everything that can
   be upstreamed, in small reviewable PRs.
2. **The sim is untouchable.** Nothing under `rts/Sim/`, `rts/lib/streflop/`, or any
   code that runs synced may change behavior, be wrapped in `#ifdef __APPLE__`, or
   acquire "harmless" optimizations. Platform work lives in `rts/System/Platform/Mac/`,
   rendering work in `rts/Rendering/`, build work in CMake. A macOS port that desyncs
   is not a port, it's a screenshot generator.
3. **The determinism contract on ARM64** (from merged PR #2819 — never regress any of it):
   - streflop NEON mode: FPCR = DN=1, FZ=0, RMode=00;
   - `-ffp-contract=off` on streflop libm **and globally** — a single compiler-emitted
     `fmadd` in synced code is a 1-ULP desync that surfaces once per dozen games;
   - sse2neon for engine SSE intrinsics, with `SSE2NEON_PRECISE_*` knobs **off**
     (they change results vs x86 SSE);
   - no `-ffast-math`, no `-Ofast`, anywhere in engine code, ever;
   - the cross-arch streflop test (`tools/sync-test`) must stay bit-exact
     (52,080/52,080 ops) against the committed x86_64 SSE reference on every change.
4. **Translate the graphics API, never shrink it.** Recoil exposes OpenGL (up to 4.6
   compat profile — yes, *compatibility* profile, deprecated features and all) directly
   to game Lua; BAR's rendering widgets call it. So the GL surface cannot be trimmed to
   what the engine itself uses. The proven route is Mesa **Zink → KosmicKrisp → Metal**
   (GL 4.6 compat on Apple Silicon, macOS 26+). Fix rendering bugs at the layer that
   owns them: engine present path → our code; GL semantics → Zink; Vulkan-on-Metal →
   KosmicKrisp/MoltenVK (report upstream, pin around).
5. **Version identity is a multiplayer requirement.** Lockstep means every client runs
   the *same engine version doing the same math*. Public-server play requires an engine
   that identifies as, and behaves as, the server's pinned version (currently
   `2025.06.24`; next `2026.06.08`). macOS engine builds are therefore made from pinned
   `macos-<version>` branches: exactly the upstream release tag + the macOS layer, no
   stray upstream drift. Development happens on latest master; *shipping* happens on pins.
6. **Artifact verification over exit codes** (inherited verbatim from GeneralsX, it
   paid for itself there twice a day): after every build check `file`/`otool -L`/
   `lipo -info` on artifacts; at runtime check the engine infolog reports
   `zink Vulkan 1.3 (Apple M… (MESA_KOSMICKRISP))` and `4.6 (Compatibility Profile)`,
   not a silent llvmpipe/software fallback (symptom: single-digit FPS, correct picture).
7. **Behavioral acceptance gates, not build gates.** "Compiles" means nothing.
   The gates are: engine boots → menu renders → skirmish loads → full AI match glitch-
   free 30+ min → replay runs bit-identical on arm64 vs x86_64 → live cross-platform
   match with zero desync. Each phase in `PORTING_PLAN.md` has its gate.
8. **Desync triage is evidence-driven.** The engine has the machinery: synced-state
   checksums, `SyncChecker`, replay (demo) files that embed them, headless engine for
   reproduction. A desync is debugged by bisecting *which frame, which unit, which
   subsystem* diverged via checksum comparison between an arm64 and an x86_64 run of
   the same demo — never by guessing at compiler flags.
9. **Respect the two-compiler risk.** Linux/Windows BAR ships gcc; on macOS we ship
   AppleClang end-to-end. streflop makes FP results compiler-independent *where
   streflop is used*; everything else synced relies on IEEE754 + identical operation
   order. Any new desync with no obvious cause: first suspect UB/order-of-evaluation
   differences between gcc and clang, and check whether the same demo desyncs on
   clang-built *Linux* (isolates compiler from platform).
10. **Document as you go.** Every fix lands with: symptom → root cause → fix →
    file. Every painful lesson becomes a numbered entry in `docs/LESSONS.md`. On
    a port like this the documentation is the velocity — and the eventual
    upstream PR description.
11. **Custom library builds stay project-local — never installed machine-wide —
    and every run verifies at runtime which copy actually loaded** (user rule,
    2026-07-11). Custom builds (Mesa/KosmicKrisp, SPIRV translator, …) install
    only under `deps/` and reach the process via per-run env vars
    (`VK_ICD_FILENAMES`, `DYLD_FALLBACK_LIBRARY_PATH`, …). Because env-var
    linking can silently fall back to another installed driver (brew ships
    molten-vk + vulkan-loader on this box), runtime identity must be logged
    and checked unless a fallback is provably impossible: KosmicKrisp prints
    `KOSMICKRISP_LOADED version=… path=…` (dladdr) at vkCreateInstance, the
    infolog's `Mesa …-devel (git-…)` line identifies the GL stack, and
    `perf-bench.sh` asserts the path is under `deps/mesa-native/` and the sha
    matches `deps/mesa-src` HEAD (hard-fails the run on a wrong driver).

## 2. Per-subsystem strategy (the GeneralsX decision table, instantiated for Recoil)

| Subsystem | Strategy | Concrete choice |
|---|---|---|
| Rendering (GL 4.6 compat) | **Translate** | Mesa Zink → KosmicKrisp → Metal. Alternative under evaluation: Zink → MoltenVK (reportedly faster, needs capability spoofing). Never a Metal rewrite — unmaintainable and it forks the Lua-visible GL surface. |
| Present/swapchain | **Swap** (engine seam) | Surfaceless EGL pbuffer → IOSurface zero-copy → CAMetalLayer (`rts/System/Platform/Mac/MetalPresent.mm`). SDL2 owns the window; Metal owns the present. |
| Windowing/input | **Keep** | SDL2 is already the engine's platform layer and is first-class on macOS. Points-vs-pixels handled at the boundary (persist logical size, render backing size). |
| Audio | **Swap** | openal-soft (brew) — Apple's deprecated OpenAL.framework lacks needed extensions (alext/efx). |
| Synced FP / SIMD | **Contract** | streflop NEON + sse2neon + `-ffp-contract=off` global (PR #2819). This is *the* port-defining subsystem; see Golden Rule 3. |
| OS plumbing (CPU topology, thread QoS, crash handler) | **Shim** | Per-OS files in `rts/System/Platform/Mac/` mirroring the Linux/Windows siblings. P/E-core detection feeds the engine's thread-pinning logic. |
| Content delivery | **Reuse + patch** | pr-downloader (ExaDev fork: HTTP/1.1 fix for the BAR CDN on macOS). |
| Lobby/launcher | **Reuse** | BYAR-Chobby runs inside the engine (LuaMenu); bar-lobby is Electron and runs natively. Packaging only. |
| AI (BARb etc.) | **Defer, then fix compile** | `AI_TYPES=NONE` until the engine is solid; skirmish AI is required for Phase A gate, so bring BARb up right after first render. |

## 3. Known portability traps (already hit by prior efforts — check proactively)

- **Homebrew header shadowing**: `/opt/homebrew/include` leaks into includes and
  shadows vendored libs (simdjson bit ExaDev; fmt bit GeneralsX). Fix with
  include-`BEFORE` pins, never by deleting brew packages.
- **brew Mesa is not enough**: KosmicKrisp needs Mesa ≥26.2-devel (`VK_EXT_robustness2`
  nullDescriptor for Zink) and macOS 26+ (Metal 4). brew LLVM can't link Mesa's CLC
  step — build the matched LLVM-19 + SPIRV-LLVM-Translator v19.1.7 toolchain from source.
- **macOS 26 SIGKILLs unsigned Mach-O**: ad-hoc `codesign --force -s -` every binary
  and dylib after `install_name_tool` surgery (which invalidates signatures).
- **rpath model**: single `@rpath/<base>` id per dylib + one `LC_RPATH` of
  `@executable_path/lib` per binary; per-binary relative prefixes break dylib→dylib deps.
- **Points vs pixels**: persist the *logical* window size in config, size the drawable
  in *pixels*; a mismatch shows as corner-rendering or drifting clicks (GeneralsX §4).
- **EGL teardown**: destroy the context via EGL, not `SDL_GL_DeleteContext` (shutdown crash).
- **LuaSocket in LuaMenu**: `socket.lua` must load from base-content VFS or lobby
  networking silently dies.
- **Quarantine/Gatekeeper**: ad-hoc-signed apps read as "damaged" until
  `xattr -dr com.apple.quarantine`.
- **Case sensitivity / path separators**: engine VFS already handles this (Linux
  heritage) — but external tooling (scripts, asset staging) must not assume either way.
- **Sync-visible allocator/hash-order effects**: `MemPoolTypes`, `SpringHashMap`
  needed macOS fixes in the ExaDev set; treat any container/allocator change as
  sync-suspect and run the determinism gate.

## 4. Verification ladder (run the cheapest gate that can catch the change)

1. `tools/sync-test` streflop cross-arch bit-exactness (seconds; any FP/flag/compiler change).
2. Engine + headless build, `file`/`otool` artifact checks (minutes; any build change).
3. Runtime infolog: renderer string, GL version, no llvmpipe (any graphics-stack change).
4. Scripted headless skirmish (engine vs BARb AI) N-minute run, exit clean (any engine change).
5. **Replay determinism**: same BAR demo file replayed headless on macOS-arm64 and on
   the x86_64 reference machine; synced checksums must match every frame (any change
   touching anything sync-adjacent; nightly).
6. Live cross-platform match vs x86_64 (LAN spring-dedicated, then public server)
   (before any release; after any sim-adjacent change).
7. Human play session with eyes and ears — logs cannot see visual glitches, wrong
   colors, missing healthbars, or a "chirp" (GeneralsX §8.3). Screenshot/screen-record
   and compare against reference-platform footage of the same scenario.

## 5. Process rules

- **Keep a work journal**: every session ends with state + blockers + exact next
  step (context recovery is the #1 agent cost).
- **Pinned everything**: Mesa commit, SPIRV-LLVM-Translator tag, engine branch, BAR
  game version used for testing — recorded in `docs/VERSIONS.md`. "Latest" is not a version.
- **One category per commit**; platform code never mixed with build tweaks or (never)
  sim changes. Commit messages follow upstream conventions (`fix(macos): …`).
- **Upstream radar**: upstream RecoilEngine master moves fast (a desync fix landed
  2026-07-11). Sync with upstream and with ExaDev regularly; prefer consuming their
  fixes over re-deriving them; report ours back.
- **Fix at the layer you control, pin the layers you don't**: our engine patch set is
  ours; Mesa/KosmicKrisp bugs get reported upstream with a pinned-commit workaround
  in our build scripts, not source hacks in `_deps`-style checkouts.
- **Front-load anything needing the human**: Apple ID/signing decisions, accounts on
  the BAR public server, the x86 reference machine's availability window.
