# Sync validation — method, extent, and limits

Beyond All Reason is lockstep-deterministic: every client simulates the whole
game and only player *commands* cross the network. That only works if every
machine computes **bit-identical** floating-point results for every one of
millions of operations per game. A port that gets one bit wrong anywhere in
the simulation desyncs — worst case mid-game, for every player in the match.

We assumed this port would break sync, and set out to prove that it did.
This document describes exactly what was tested, how you can reproduce it,
and what remains unproven. Numbers below are from the certification runs of
the build this fork ships; every claim states its evidence.

## How sync is measured (for non-engine-devs)

The engine computes a checksum of the synced simulation state every frame
(`SyncChecker`). Recorded games (demos, `.sdfz`) embed the checksums the
recording client computed. Re-simulating a demo (`spring-headless` replays
the command stream through the full simulation) recomputes every frame's
checksum and compares against the recorded ones: one bit of divergence in
any unit position, projectile, RNG draw, or economy value fails the run with
a sync error. A full-length 8v8 demo is therefore a test with tens of
thousands of consecutive per-frame assertions over the entire sim codebase.

## 1. Floating-point foundation: streflop bit-exactness

The engine's synced math runs on streflop (ARM64/NEON support merged
upstream in PR #2819). The cross-architecture test suite exercises 52,080
operations (all libm entry points over denormals, near-branch-cut values,
huge/tiny args) and compares bit patterns:

- AppleClang arm64 NEON build vs the committed arm64-NEON reference:
  **52,080 / 52,080 bit-exact**.
- vs the committed x86_64-SSE reference: **47,852 / 47,852 bit-exact**
  (result-set hash `EA2881A4F127BF10`).
- Same binary run natively (arm64) vs under Rosetta 2 (x86_64-SSE):
  **52,080 / 52,080 bit-exact**.

Reproduce: build `tools/sync-test` (in this tree) and run it against the
committed references under `tools/sync-test/reference/`.

## 2. Fleet libm parity: the hybrid streflop build

Linux/Windows release builds are compiled with gcc, which passes
`-fsingle-precision-constant` — a gcc-only flag that demotes unsuffixed FP
literals in streflop's double-precision libm to float precision. Clang has
no equivalent, so a pure-clang build diverges from the fleet by up to ~45
ULPs in `asin`/`acos`-family results. The shipping build therefore swaps the
affected dbl-64 object(s) with gcc-built ones and verifies the result: a
9-function hash harness (atan2, sin, cos, tan, floor, fmod, sqrt/log,
asin/acos, exp/atan chains over large deterministic input sweeps) must match
the hashes produced by a gcc x86-64 Linux build **9 / 9**. This check is a
mandatory step of the release build; a build that fails it does not ship.

## 3. Full-game replay certification vs official recordings

Demos recorded by **official builds** (public releases played by the live
community) re-simulated on this port, every frame checksum-compared:

| Demo | Frames | Result |
|---|---|---|
| Public replay matrix (6 demos, mixed maps/modes) | — | 6/6 PASSED |
| Iron Isle 8v8 (48 min) | 86,632 | PASSED, zero sync errors |
| Rosetta 8v8 (53 min) | 87,936 | PASSED, zero sync errors |
| All That Glitters 8v8 | 92,040 | PASSED, zero sync errors |
| Final certification: public-release 8v8 | 66,589 | REPLAY_SYNC_OK, zero sync errors |

Reproduce: `spring-headless <demo.sdfz>` with the matching game/map content
present; watch for `Sync error` lines (none should appear) and the final
sync-OK verdict. Any public BAR replay recorded on engine 2025.06.24 works.

## 4. Live cross-platform multiplayer (the real thing)

Replays prove the sim; live games additionally prove the network path, and
the server compares checksums across *different* machines in real time.

**Phase B3 — vs the official Linux release binary** (unmodified release
download, x86-64, running in a VM): both hosting directions, smoke games,
full 1v1s to natural game end (f≈38,753 and f=18,172), and a 16-player
8×AI 4v4 — all with zero sync errors.

**Phase B4 — vs the official Windows release binary** (unmodified release,
running natively on a separate x86-64 Windows machine, real LAN):

| Stage | Result |
|---|---|
| Smoke 1v1, both hosting directions | PASS (natural ends f=28,912 / f=15,894) |
| 16-player 8×AI 4v4 | PASS, natural end f=24,242 |
| Protocol surface: pause, speed force/restore, resign, late-spec join/disconnect/rejoin | PASS |
| Raptors PvE (exercises the fleet-parity floor fix) | PASS, natural end f=25,877 |
| Scavengers PvE | PASS, natural end f=27,646 |
| Soak ×3, alternating hosts | PASS: f=34,504 / 100,657 / 43,450, zero desyncs |

The 100,657-frame soak game is ~56 minutes of continuous live lockstep
against an official Windows client.

## 5. Honest limitations

- **Replays exercise recorded content only.** Code paths no recorded game
  hits are not covered by §3. The live matrix (§4) and PvE modes broaden
  this, but coverage is necessarily of what was played.
- **Every engine or game-version bump requires re-validation.** These
  results certify this exact engine tree and driver stack. The gate suite
  (streflop sync-test, 9/9 libm hashes, replay re-simulation) reruns per
  release, and any compiler or flag change triggers the full-length replay
  certification again.
- **Compiler risk is managed, not eliminated.** The fleet ships gcc; this
  port ships AppleClang plus the gcc object swap (§2). Outside streflop,
  identical results rely on IEEE-754 semantics with `-ffp-contract=off`
  globally and no fast-math anywhere in synced code (the Metal shader
  fast-math option affects only unsynced rendering — shaders never feed the
  simulation).
- **Marathon headless re-simulations can end early on the game's Lua memory
  ceiling, not on sync.** The engine's Lua allocator budget (a game modrule,
  1.5 GB) is counted globally across synced and unsynced Lua; a flat-out
  re-simulation of a very long 8v8 with the full UI widget set loaded can
  brush that ceiling and exit — with every frame up to that point still
  checksum-verified, and at a different frame on each run (allocator/GC
  noise, not simulation state). Observed on this port only within ~1% of the
  end of the longest (92k-frame) demo; the same class of Lua memory pressure
  is visible on official binaries in long headless runs. Live games are
  unaffected (our longest live soak game ran 100,657 frames).
- **Desync triage is built in.** `SPRING_DUMP_STATE_RANGE=min:max` dumps
  full synced state (RNG, units, features, projectiles, raw floats) per
  frame in the range, so any reported desync can be bisected to the exact
  frame and subsystem against a reference dump.

## 6. Before this client touches public servers

The plan of record, in order: share this document with BAR maintainers and
server admins; agree a rollout (e.g. unranked/beta flag first); ship with a
version string that clearly identifies the macOS port build so server-side
triage is trivial; commit to a fast-pull policy if any live desync is ever
attributed to this port. None of that has happened yet — this fork is not
cleared for ranked play until it has.
