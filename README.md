# Recoil engine — native Apple Silicon (macOS) port

**Built on [ExaDev's macOS fork](https://github.com/ExaDev/RecoilEngine) of the
[Recoil engine](https://github.com/beyond-all-reason/RecoilEngine)** (the engine
behind [Beyond All Reason](https://www.beyondallreason.info/)). ExaDev did the
foundational Apple Silicon bring-up — the first working builds, the
surfaceless-EGL → Zink path, Apple-Silicon CMake support, and the ARM64
deterministic floating-point work now
[merged upstream](https://github.com/beyond-all-reason/RecoilEngine/pull/2819).
**This branch is a thin layer of render/present hardening and packaging on top
of their work**; their commits (and the upstream Recoil commits they carry) form
its base and keep their original authorship — see [Credits](#credits).

The result runs **natively on Apple Silicon Macs**: arm64 end to end, OpenGL 4.6
compatibility profile via Mesa's Zink on
[KosmicKrisp](https://lunarg.com/kosmickrisp/) (Vulkan-on-Metal), no Rosetta,
no fidelity compromises. Upstream's own README is
[README-upstream.markdown](README-upstream.markdown); this file covers the macOS port.

Pinned to engine version **2025.06.24** — the version the live BAR fleet
runs — so it plays with, and simulates bit-identically to, the official
releases.

## What works

- **Full game, online-compatible simulation.** The port is sync-certified
  against official builds: bit-exact lockstep over full-length 8v8 replays
  (up to 92,040 frames) and live LAN games versus unmodified official Linux
  and Windows release binaries, including 16-player games and PvE modes,
  with zero sync errors. Method, numbers, reproduction commands, and honest
  limits: **[SYNC_VALIDATION.md](SYNC_VALIDATION.md)**. Not yet cleared for
  public ranked servers — see the community process in that document.
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

GPL v2 or later, same as upstream — see [COPYING](COPYING). Complete
corresponding source for every shipped binary is this repository plus the
pinned/patched dependency set documented in the release notes.

## Reporting issues

Open a GitHub issue with your `infolog.txt` (it includes the one-line
driver-identity print so we can see which GL stack actually loaded). For
anything that looks like a sync/desync problem, please say so in the title —
those get priority and a documented triage path (see SYNC_VALIDATION.md §5).
