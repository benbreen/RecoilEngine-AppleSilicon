# Beyond All Reason — for macOS (Apple Silicon)

<p align="center">
  <a href="https://github.com/benbreen/BeyondAllReason-Apple/releases/latest"><img src="https://img.shields.io/github/v/release/benbreen/BeyondAllReason-Apple?logo=apple&label=download&color=1793d1" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-black?logo=apple" alt="macOS · Apple Silicon">
  <a href="https://github.com/benbreen/BeyondAllReason-Apple/releases"><img src="https://img.shields.io/github/downloads/benbreen/BeyondAllReason-Apple/total?color=44cc11" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/license-GPL--2.0-blue" alt="License: GPL-2.0">
  <img src="https://img.shields.io/badge/built%20on-Recoil-orange" alt="Built on the Recoil engine">
</p>

> ⚡️ **A Claude Fable port.** The macOS layer in this repository was built
> largely by **[Claude Fable](https://www.anthropic.com)** (Anthropic's Claude
> model), on top of ExaDev's foundational macOS work — see
> [What this project did](#what-this-project-did).

<p align="center">
  <a href="https://github.com/benbreen/BeyondAllReason-Apple/releases/latest"><b>⬇&nbsp; Download for macOS (Apple Silicon)</b></a>
  &nbsp;·&nbsp; requires an Apple Silicon Mac on macOS 26+
</p>

<p align="center">
  <img src="screenshots/hero.jpg" alt="Beyond All Reason running natively on macOS (Apple Silicon)" width="100%">
  <br><em>Beyond All Reason running natively on an Apple Silicon Mac.</em>
</p>

**[Beyond All Reason](https://www.beyondallreason.info/) is a free, open-source
real-time strategy game. This project lets you play it natively on Apple Silicon
Macs** — no Rosetta, no virtual machine — with full graphics and full online
multiplayer against Windows and Linux players in the same lobbies.

The game runs on the [Recoil engine](https://github.com/beyond-all-reason/RecoilEngine)
— the program that actually runs the game: its simulation, graphics, and
networking. The engine ships for Windows and Linux; this repository is a native
macOS build of it, delivered as a signed, notarized `.app` you download and open
like any other Mac app. Under the hood it renders through Apple's Metal
(OpenGL 4.6 → Mesa Zink → [KosmicKrisp](https://lunarg.com/kosmickrisp/) →
Metal) and simulates bit-identically to the official builds, so Mac players
share the same ranked matches and replays as everyone else. Pinned to engine
version **2025.06.24**, the version the live fleet runs.

## What this project did

The macOS *foundation* — the first working Apple Silicon builds, the
surfaceless-EGL → Zink graphics path, and the ARM64 deterministic-math work now
[merged into the official engine](https://github.com/beyond-all-reason/RecoilEngine/pull/2819)
— comes from [ExaDev's macOS fork](https://github.com/ExaDev/RecoilEngine), whose
commits keep their authorship here (full [Credits](#credits) below).

This repository is the substantial layer built on top of that foundation,
developed largely by **Claude Fable** (Anthropic's Claude model) with direction
from the maintainer — not a thin wrapper:

- **A rebuilt macOS graphics-present path.** The EGL/Metal context and the whole
  read-back-and-present pipeline were extracted into a proper `Platform/Mac`
  backend, and the driver stalls and bugs that made the earlier path unshippable
  were fixed.
- **A one-command, reproducible build-and-release pipeline.** `make app` builds
  the graphics driver from pinned upstream source, builds the engine, runs the
  determinism gates, and produces the signed, notarized, drag-to-install
  `.app`/`.dmg` — nothing fetched or built by hand ([details below](#building-the-macos-app)).
- **A month-one performance campaign** taking heavy late-game scenes from
  single-digit frame rates to display-class ones at 5K, pixel-identical (table
  below).
- **Multiplayer sync certification** — bit-exact lockstep proven over
  full-length replays and live cross-platform matches (see
  [SYNC_VALIDATION.md](SYNC_VALIDATION.md)).
- **Native-Mac behaviour** — correct window title, Cmd-based clipboard, a Cmd+Q
  guard so a reflex keystroke can't abandon a live match, Local-Network
  permission handling, and loud failure instead of a silent slow software
  fallback.

Upstream's own engine README is
[README-upstream.markdown](README-upstream.markdown); this file covers the macOS
build.

## What works

- **Full game, online-compatible simulation.** The port is sync-certified
  against official builds: bit-exact lockstep over full-length 8v8 replays
  (up to 92,040 frames) and live LAN games versus unmodified official Linux
  and Windows release binaries, including 16-player games and PvE modes,
  with zero sync errors. Method, numbers, reproduction commands, and honest
  limits: **[SYNC_VALIDATION.md](SYNC_VALIDATION.md)**.
- **Native performance.** A month-one optimization campaign took the heavy
  late-game scenes from single-digit to display-class frame rates at 5K with
  pixel-identical output (measured on an M2 Ultra Mac Studio, vsync on):

  | Scene | Before | After |
  |---|---|---|
  | 2,162-unit battle arena | 6.8 fps | 54.4 fps (8.0×) |
  | 1,082-unit battle, combat zoom | 12.1 fps | 71.7 fps (5.9×) |
  | Late-game 8v8, icon overview | 4.7 fps | 45.5 fps (9.7×) |
  | Early game | 50.6 fps | display-limited (120 Hz) |

  What changed and why, with the methodology:
  **[IMPROVEMENTS.md](IMPROVEMENTS.md)**.
- Retina/HiDPI, dynamic window resize, borderless fullscreen, lobby
  (Chobby) networking, music/effects via openal-soft, P/E-core-aware
  threading.

## Screenshots

<p align="center">
  <img src="screenshots/battle.jpg" width="49%" alt="A battle mid-map — two armies clashing with the full HUD">
  <img src="screenshots/valley.jpg" width="49%" alt="An army massing in a mountain valley">
  <br><em>Real matches, full interface — captured on macOS. (More in the game itself.)</em>
</p>

## Requirements

- Apple Silicon Mac (developed/benchmarked on M2 Ultra; the graphics work
  targets Apple's TBDR GPUs generally).
- macOS 26+ (KosmicKrisp needs Metal 4).
- Game content downloads from the official BAR content network on first run
  (not bundled; served by the BAR project's infrastructure).

## Known limitations (honest ones)

- Late-game 8v8 frame rate is bounded ~60–70 fps by single-threaded
  simulation + game-Lua on the main thread — an upstream engine property,
  not a graphics-stack limit on this port.
- Memory footprint is healthy on desktop (≈7.4 GB RSS in late-game 8v8) but
  heavy for smaller devices.
- Geometry shaders are unavailable (Metal has no geometry stage); BAR does
  not require them.

## Building / stack

The GL stack is upstream Mesa (Zink + KosmicKrisp) at a pinned commit plus
a three-patch series maintained both as a Mesa fork branch and as plain
`patches/mesa/*.patch` — the driver is reproducible from pure upstream
source. Engine-side macOS work is a curated, reviewable commit series on
top of the upstream release tag, written to be upstreamable piecewise.

## Runtime knobs

One policy: **user-facing switches are registered springsettings config
variables** (discoverable, documented, changeable from the game); **env vars
are support/debug escape hatches**, and anything heavier is compiled out of
release builds behind `-DSPRING_MAC_DIAGNOSTICS=ON`.

Config (springsettings.cfg):

| Key | Default | Meaning |
|---|---|---|
| `MacPresentDirect` | 1 | Present shader reads the readback ring directly from unified memory; 0 = IOSurface staging path. Runtime-changeable. |
| `MacWorkerQos` | 1 | Sync-pool ThreadPool workers request USER_INITIATED QoS (prefer the performance cluster). Runtime-changeable. |
| `WindowTitle` | "" | Window title; `{version}` expands to the engine version. Empty = engine default. |

Environment (support escape hatches; all default off/unset):

| Var | Effect |
|---|---|
| `SPRING_MAC_NO_RETINA=1` | Render at logical 1x and let CoreAnimation upscale (readback cost /4 on Retina). |
| `SPRING_MAC_GL_CORE=1` | Force a core-profile GL context (compat is the default and the supported mode). |
| `SPRING_MAC_LEGACY_PRESENT=1` | CPU-staging present path (the pre-optimization fallback). |
| `SPRING_ALLOW_SOFTWARE_GL=1` | Permit the llvmpipe/softpipe fallback instead of failing loudly. |
| `SPRING_EGL_FULL_TEARDOWN=1` | Real EGL teardown at exit (debug the driver shutdown race; default is fast-exit). |
| `SPRING_NO_STALL_LOG=1` | Silence the >150ms draw-gap stall log lines. |
| `SPRING_MAC_STREAM_BUFFERING=n` | Stream-buffer ring depth 2..8 (default 3). |
| `SPRING_LUAVAO_FORCE_RESTART=1` | Restore upstream primitive-restart behavior on list topologies. |
| `KK_MATH_MODE=safe\|relaxed\|fast` | KosmicKrisp shader-compiler math mode (engine defaults it to `fast`). |
| `SPRING_DUMP_STATE_RANGE=min:max` | Dump full synced state per frame in the range (desync triage; local analysis only). |

Diagnostics builds only (`cmake -DSPRING_MAC_DIAGNOSTICS=ON`; not compiled
into releases): `SPRING_MAC_PRESENT_TEST`, `SPRING_FRAME_CAPTURE[_EVERY/_LIMIT]`,
`SPRING_MAC_DUMP_FRAME`, `SPRING_TIME_PRESENT`, `SPRING_MAC_PRESENT_LAG`,
`SPRING_MAC_PRESENT_GPUPACK`.

## Documentation

Deeper docs live alongside the code — start with **AGENTS.md** if you want to
work on the port (with or without an AI agent).

| Document | What it is |
|---|---|
| [AGENTS.md](AGENTS.md) | Start here to work on the port: read-order, the hard rules, and how to build. Written so an AI coding agent can get up and running. |
| [docs/PORTING_PRINCIPLES.md](docs/PORTING_PRINCIPLES.md) | The golden rules — the determinism contract, sim untouchability, per-subsystem strategy, and the verification ladder. |
| [SYNC_VALIDATION.md](SYNC_VALIDATION.md) | How multiplayer bit-exactness is proven: method, numbers, reproduction commands, and honest limits. |
| [IMPROVEMENTS.md](IMPROVEMENTS.md) | What the port changes and why — each entry symptom → cause → fix → measured result. |
| [docs/MAINTENANCE.md](docs/MAINTENANCE.md) | How the macOS layer rides upstream: the version-bump / rebase-onto-a-new-release procedure. |
| [docs/AGENT_FAILURE_MODES.md](docs/AGENT_FAILURE_MODES.md) | What halts or silently misleads an automated agent on macOS (dialogs, permissions, fallbacks). |
| [docs/LESSONS.md](docs/LESSONS.md) | Numbered, citable gotchas already hit during the port. |
| [docs/UPSTREAM_CANDIDATES.md](docs/UPSTREAM_CANDIDATES.md) | Fixes in this layer that belong upstream, so the patch series shrinks over time. |
| [docs/VERSIONS.md](docs/VERSIONS.md) | Pinned versions (engine, driver, toolchain) and why each is pinned. |
| [docs/SOUND_WARNINGS_CATALOG.md](docs/SOUND_WARNINGS_CATALOG.md) | Reference for the audio-subsystem warnings you may see in the log. |

## Credits

This port stands on a lot of prior work, gratefully:

- **[ExaDev](https://github.com/ExaDev/RecoilEngine)** — the foundational
  macOS fork: first working builds, EGL/Zink bring-up, pr-downloader fixes.
  Their commits form the base of this series, preserved with attribution.
- **The Recoil engine team** — especially the ARM64 deterministic
  floating-point work merged in
  [PR #2819](https://github.com/beyond-all-reason/RecoilEngine/pull/2819),
  without which cross-platform lockstep on Apple Silicon would not exist.
- **The Beyond All Reason project** — the game, the content network, and
  the reason any of this is worth doing.
- **Mesa / Zink** and **KosmicKrisp** (LunarG, Google) — the driver stack
  that makes GL 4.6 compatibility profile on Metal real.
- **SDL2, openal-soft, streflop**, and the rest of the dependency tree.
- Porting methodology informed by the
  [C&C Generals Apple port](https://github.com/ammaarreshi/Generals-Mac-iOS-iPad)
  (built on [GeneralsX](https://github.com/fbraz3/GeneralsX)).

## License

**GPL-2.0-or-later**, same as the upstream Recoil engine — full text in
[LICENSE](LICENSE). Bundled components keep their own compatible licenses
(streflop/vendored libm under LGPL, the SDL/OpenAL/Mesa stack under MIT/BSD/zlib
— see [COPYING](COPYING) and the component directories). Complete corresponding
source for every shipped binary is this repository plus the pinned/patched
dependency set documented in the release notes.

## Reporting issues

Open a GitHub issue with your `infolog.txt` (it includes the one-line
driver-identity print so we can see which GL stack actually loaded). For
anything that looks like a sync/desync problem, please say so in the title —
those get priority and a documented triage path (see SYNC_VALIDATION.md §5).
