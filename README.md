# Recoil engine — native Apple Silicon (macOS) port

This is a fork of the [Recoil engine](https://github.com/beyond-all-reason/RecoilEngine)
(the engine behind [Beyond All Reason](https://www.beyondallreason.info/)) that
runs **natively on Apple Silicon Macs**: arm64 end to end, OpenGL 4.6
compatibility profile via Mesa's Zink on
[KosmicKrisp](https://lunarg.com/kosmickrisp/) (Vulkan-on-Metal), no Rosetta,
no fidelity compromises. Upstream's own README is
[README.markdown](README.markdown); this file covers the macOS port.

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
