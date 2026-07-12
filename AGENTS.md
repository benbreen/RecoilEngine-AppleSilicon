# Beyond All Reason (macOS) — working on this port with an AI agent

This is the macOS/Apple Silicon layer on top of the [Recoil engine](https://github.com/beyond-all-reason/RecoilEngine)
(the engine behind Beyond All Reason). If you're pointing an AI coding agent at
it, read these first — they are what keep the port shippable and, above all,
**multiplayer-deterministic**.

**Read in order before doing any work:**

1. [`docs/PORTING_PRINCIPLES.md`](docs/PORTING_PRINCIPLES.md) — the golden rules:
   the determinism contract, sim untouchability, per-subsystem strategy, and the
   verification ladder. Non-negotiable.
2. [`docs/AGENT_FAILURE_MODES.md`](docs/AGENT_FAILURE_MODES.md) — read before any
   unattended run. What halts an agent on macOS (GUI dialogs, permission prompts,
   privileged-command denials, stuck audio) and what silently hides problems
   (fallbacks, blind crash handler, config rewrites).
3. [`docs/LESSONS.md`](docs/LESSONS.md) — numbered, citable gotchas already hit.
4. [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) — how the macOS layer rides
   upstream: the version-bump / rebase-onto-a-new-release procedure. Read before
   bumping the engine version.
5. [`docs/UPSTREAM_CANDIDATES.md`](docs/UPSTREAM_CANDIDATES.md) — fixes here that
   belong upstream (the patch series should shrink over time).
6. [`docs/VERSIONS.md`](docs/VERSIONS.md) — pinned versions. Never bump a pin
   silently.

## What this is

A native Apple Silicon build of the Recoil engine so Beyond All Reason runs on
macOS with full graphics (OpenGL 4.6 via Mesa Zink → KosmicKrisp → Metal) and
**bit-exact cross-platform multiplayer** — a Mac client simulates identically to
the Windows/Linux builds it plays against. That determinism requirement drives
every rule below.

## Hard rules (rationale in PORTING_PRINCIPLES.md)

- **Nothing under `rts/Sim/` or `rts/lib/streflop/` changes behavior. Ever.**
  A macOS port that desyncs is not a port. Platform work lives in
  `rts/System/Platform/Mac/`, rendering work in `rts/Rendering/`, build work in
  CMake.
- **No `-ffast-math`/FMA anywhere**; `-ffp-contract=off` stays global (a single
  compiler-emitted `fmadd` in synced code is a 1-ULP desync).
- **Translate the GL API, never shrink it.** Recoil exposes GL 4.6 *compatibility*
  profile to game Lua; the route is Mesa Zink → KosmicKrisp → Metal, never a
  Metal rewrite.
- **Verify artifacts, not exit codes** — `file`/`otool -L`/`lipo`, and at runtime
  the GL renderer string (must be KosmicKrisp/Zink, not a software fallback).
- **Version identity is a multiplayer requirement.** Ship from the pinned
  upstream release tag + this macOS layer; the engine must report, and simulate
  as, the version the live fleet runs.
- **Commit style**: `fix(macos): …`; one concern per commit; keep the patch set a
  thin, rebaseable series on upstream.

## Building

The engine here builds against a Mesa Zink+KosmicKrisp driver and is packaged
into a signed, notarized `.app`. The build/packaging tooling (driver build,
`make app`, launcher, license audit) lives in the companion packaging project;
see the main [README](README.md) "Building the macOS app" for the one-command
flow and prerequisites.
