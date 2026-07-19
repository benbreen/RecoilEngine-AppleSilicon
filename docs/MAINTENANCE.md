# Maintenance — how the macOS layer rides upstream

The port's survival thesis (PORTING_PRINCIPLES §1.1): **every unmergeable macOS
mega-fork has died** when its maintainer left. So the macOS work is kept as a
*thin, rebasable patch series on top of an upstream release tag*, not a
divergent fork. This doc is the procedure for keeping it that way.

## Branch model

```
upstream release tag (e.g. 2025.06.24)         ← beyond-all-reason/RecoilEngine
        │
        └── macos-<version>     = the tag + the macOS layer
                                  (upstream cherry-picks the tag predates +
                                   the platform / render / packaging work)
```

The macOS layer is what sits between the upstream tag and the branch tip. Keep it
**reviewable and scoped** so each piece can be upstreamed and so a rebase onto
the next tag is mechanical:
- platform code under `rts/System/Platform/Mac/`;
- rendering/present under `rts/Rendering/` and `Platform/Mac/MacPresentBackend`;
- cross-platform features (e.g. `WindowTitle`) unscoped and generic — no
  `#ifdef __APPLE__`, so upstream can take them as-is;
- **nothing under `rts/Sim/` or `rts/lib/streflop/` changes behavior** except
  the deterministic-FP work, which is enumerated in
  `SYNC_VALIDATION.md` Appendix A and is itself an upstream candidate.

Shipping happens on the pinned tag + macOS layer, nothing else: lockstep
multiplayer requires byte-identical simulation to the version the live fleet
runs.

## Bumping to a new upstream pin (the version-bump procedure)

When the fleet moves to a new engine version `NEW` (e.g. 2026.06.08):

1. **Branch from the upstream tag**, not from the old macOS branch:
   ```sh
   git fetch upstream --tags
   git checkout -b macos-NEW NEW
   ```
2. **Replay the macOS layer.** Rebase/cherry-pick the layer commits (the range
   `OLD_TAG..macos-OLD`, dropping the upstream cherry-picks the new tag already
   contains) onto `macos-NEW`. The commits are single-concern and rebasable by
   design.
3. **Resolve at the seams, not in Sim.** Conflicts should land in the macOS
   files above. If a conflict forces a change under `rts/Sim/` or streflop,
   stop — that is a determinism risk, not a merge chore (PORTING_PRINCIPLES §2).
4. **Re-run the gates** (all must pass on `macos-NEW` before it is a pin):
   ```sh
   scripts/build-engine.sh                 # + libm fleet-parity hash gate (9/9)
   # streflop cross-arch sync-test: BIT-EXACT vs both committed references
   # replay determinism: REPLAY_SYNC_OK on a NEW-version demo
   make certify                            # full packaging + GPU + replay cert
   ```
   Regenerate the streflop references only if the new tag deliberately changed
   streflop; otherwise a diff there is a bug, not an update.
5. **Update `docs/VERSIONS.md`** — never bump a pin silently.

## Releasing the app

`make app` (build/package, headless-safe) and `make certify` / `make release`
(adds GPU + replay certification). The engine pin is read from the built
engine (`spring --version`) and kept in `CFBundleVersion`/`EngineVersion`;
the user-facing release number comes from `packaging/PORT_VERSION`. See the
README "Building the macOS app". Long, GPU-, and content-dependent validation
is opt-in so build machines can package — mirrors upstream Recoil CI, where
the build workflow builds and a separate workflow validates.

**Every GitHub release's notes MUST start with
`packaging/release-notes-header.md` verbatim** — the persistent caution block
(unofficial port, third-party content downloaded at the user's own risk). It
mirrors the first-run consent dialog and the README caution; if one changes,
change all three.

**Every release must also review `message-config/messages/`.** Live messages
are fetched by every existing install and are version-targeted; a release that
changes behavior can make a live message wrong (e.g. when online play is
enabled, the "online disabled" messaging must be capped so it does not target
the new version — `"target": {"op": "le", "version": "<last-disabled>"}`).
Propose the concrete message changes and get the maintainer's explicit
sign-off before publishing the release.

## What to upstream (keep the layer shrinking)

`docs/UPSTREAM_CANDIDATES.md` tracks the fixes that belong upstream (LuaVAO
primitive-restart, stream-buffer wait, the float→int UB sweep, WindowTitle, …).
Every commit that lands upstream is one fewer to rebase next version — the
patch series should trend *smaller*, not larger, as the port matures.
