# Catalog: `[LoadSoundFile] could not load sound` warnings

Cataloged 2026-07-11 (cont 19) at the user's request, during the Phase B3 soak.

## TL;DR — root cause is `Sound = 0` (NullSound), NOT the macOS port, NOT content

These warnings are **benign** and appear on the **official Linux binary too**
(48 emitted by the unmodified 2025.06.24 `spring-headless` host in
`logs/mp/soak7-chain-1/host.log`, identical names). They are expected whenever
audio is disabled. **Prediction: they vanish under `SOUND=1` — confirm in the
A5 audio pass.** No gameplay/sync impact.

Ruled out:
- **Not a port bug** — official amd64-linux binary emits the same set.
- **Not missing content** — all 68 distinct named sounds EXIST as files under
  `game/sounds/**` (checked every one: 68/68 present, 0 absent).
- **Not a content/version mismatch** — both engines run the one shared
  `~/src/ports/bar/game` tree over `/Users`; a mismatch would hit both. (NB
  `game/modinfo.lua` has `version = '$VERSION'` — a source checkout with the
  template placeholder unsubstituted, i.e. not a packaged release; irrelevant
  to sound resolution but noted.)

## Mechanism (engine source)

`rts/Sim/Misc/CommonDefHandler.cpp:LoadSoundFile()` resolves a Unit/WeaponDef
sound reference (a bare logical name like `xplomed2`, no extension/dir) in this
order:
1. direct file if the name already has a sound extension — misses (bare name);
2. `sound->HasSoundItem(name)` — the sounds.lua-built registry;
3. fallback flat path `"sounds/" + name + ".wav"` — **misses because the real
   files live in subdirectories** (`sounds/weapons/xplomed2.wav`, not
   `sounds/xplomed2.wav`);
4. else → the warning.

Under real audio, `CSound` runs `game/gamedata/sounds.lua`, which auto-scans the
sound directories (`VFS.DirList`, sounds.lua:358) and registers each basename as
a SoundItem, so step 2 (`HasSoundItem("xplomed2")`) succeeds. Under `Sound = 0`,
`rts/System/Sound/Null/NullSound.h` hard-returns `HasSoundItem() → false` and
`GetSoundId() → 0`, so step 2 always fails and only the broken flat-path
fallback remains → every alias-resolved name warns once per def load.

Why our runs hit it: `mp-test.sh` inherits `Sound = 0` from the write-dir
`springsettings.cfg` (set by `run-spring.sh`'s default; NullSound sidesteps the
audio device-change churn during headless/automated runs).

## The latent engine wart (the actual "future fix" candidate)

The warning itself is a false alarm under NullSound. Two clean upstream fixes,
in preference order:
1. **Suppress the warning when audio is null**: in `LoadSoundFile`, skip the
   `LOG_L(L_WARNING, ...)` when `ISound::IsNullAudio()` — there is legitimately
   no sound system to load into, so the "could not load" message is noise.
2. **(Independent, real gap) make the step-3 fallback search subdirectories**
   instead of only `sounds/<name>.wav`, so direct-path resolution matches the
   sounds.lua auto-scan behavior. Lower value (step 2 already covers it under
   real audio) but removes the flat-path assumption.

Neither is a macOS concern — both are upstream Recoil. File against
beyond-all-reason/RecoilEngine; not part of the port's fix set.

## Case-variance note

Both `emgpuls1`/`EMGPULS1` and `SabotHit` appear (mixed case) alongside
lowercase names. On the case-insensitive mac FS and via sounds.lua's
`string:match` this resolves the same as lowercase, but on a case-sensitive
Linux FS the direct-path fallback would be case-sensitive — another reason step
2 (the registry) is the correct resolution path and step 3 is fragile.

## The 68 distinct unresolved names (all present in `game/sounds/**`)

banthstep bertha6 bigbugdie bigraptordead bimpact3 bloodsplash3 bombsmed2
bombssml1 bugdie corlevlrhit emgpuls1 EMGPULS1 fireburnshort flakhit flakhit2
flamhit1 impact junohit2 korgaim korgrestore2 korgstep lashit lasrfir2 lrpcexplo
mavgun3 mine1 newboom newboomuw nuke4 nukearm nukecor nukelaunchalarm packohit
rflrpcexplo rockhit rockhit2 rockhit3 SabotHit scavdroplootspawn sizzle
sniperhit splshbig splslrg splsmed splssml starfallchargup talondie tawf113a
tonukeex xplodep1 xplodep2 xplodragconcrete xplodragmetal xplolrg3 xplolrg4
xplomas2 xplomas2s xplomed1 xplomed2 xplomed2xs xplomed3 xplomed4 xplomed5
xplonuk2 xplonuk3 xplonuk5 xplosml2 xplosml3

(This is the distinct set across all captured logs; per-run counts vary with
which units/weapons were built. The most frequent in a full game are the
explosion sounds xplomed2/xplolrg3/xplosml3.)

## Verification checklist for the future fix
- [ ] Run one skirmish with `SOUND=1` (A5 pass) → confirm the entire warning
      class disappears (proves NullSound is the sole cause).
- [ ] If keeping NullSound for automation, apply upstream fix #1 to silence.
