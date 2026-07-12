# Improvements — what this port changes and why

Every entry: symptom → root cause → fix → measured result, on the theory
that the *why* is more useful to the community than the diff. Measurements
are from a fixed benchmark corpus (recorded demos + fixed camera cells,
vsync on, 5K output, M2 Ultra) unless stated. Several entries are candidates
for upstream PRs — marked **[upstream candidate]**; we'd love review and
better ideas on any of them.

The one-line summary of the whole campaign: the port went from 6.8 fps to
54.4 fps on a 2,162-unit battle (8.0×), with pixel-identical rendering, by
fixing how the GL-on-Metal translation stack was being fed — not by
reducing what is drawn.

## Performance

### 1. Primitive restart was forcing a compute prepass on 94% of draws  [upstream candidate]

- **Symptom:** heavy battle scenes at 6.8 fps; Metal System Trace showed
  hundreds of small command buffers per frame and a compute dispatch paired
  with nearly every draw.
- **Cause:** `LuaVAOImpl` enables `GL_PRIMITIVE_RESTART` around every
  indexed draw — including `Submit()`, which is hard-coded
  `GL_TRIANGLES` multi-draw-indirect — with restart index `0xffffff` for
  32-bit buffers. Metal's restart index is fixed all-ones, so a
  Vulkan-on-Metal driver honoring `primitiveTopologyListRestart` must
  unroll the index buffer in a compute prepass, per draw. Native desktop
  drivers ignore restart on list topologies, so this is invisible upstream.
- **Fix:** enable restart only for strip/loop/fan topologies, where it has
  meaning. List-topology index streams produced by the engine and game
  never contain sentinels. Escape hatch: `SPRING_LUAVAO_FORCE_RESTART=1`.
- **Result:** 2,162-unit arena 6.8 → 23.1 fps. No visual change (verified
  by screenshot comparison). No-op on native desktop drivers, helps every
  GL-translation backend (Zink on Metal, ANGLE, portability stacks).

### 2. Present-path readback was serializing against the whole frame

- **Symptom:** `SwapBuffers` cost ~66% of heavy frames (~114 ms mean swap
  in a 2,700-unit scene).
- **Cause:** the port presents by reading the default framebuffer back and
  compositing to a `CAMetalLayer` (Zink has no macOS window-system path).
  Any `glReadPixels` of the just-rendered frame on this stack falls back to
  a synchronous CPU map that waits for the entire GPU pipeline.
- **Fix (layered):**
  - glReadPixels writes straight into an IOSurface-backed `MTLTexture`
    (zero CPU intermediate, no CPU Y-flip — a one-triangle Metal pass
    flips while compositing);
  - reads go through a PBO ring on Mesa's GPU-pack path (a compute-shader
    pack into a linear buffer; mapping an idle linear buffer needs no GPU
    round-trip), with a configurable 2-frame pipeline
    (`SPRING_MAC_PRESENT_LAG`, `SPRING_MAC_PRESENT_GPUPACK`);
  - the discovery tool was a 200-line standalone GL readback benchmark;
    the gating requirements (pack buffer bound + non-swizzling format
    pair) are documented for other zink-on-Metal consumers.  [upstream candidate — st/readpixels perf warning or swizzle-capable pack shader]
- **Result:** present cost 30 ms → ~1.3 ms at 5120×2160; arena cell
  23.1 → 30.8 fps.

### 3. nextDrawable pacing capped light scenes at exactly half refresh  [upstream candidate — documentation]

- **Symptom:** early-game scenes pinned at exactly 60 fps on a 120 Hz
  panel; the main thread blocked ~12 ms/frame inside `nextDrawable`.
- **Cause:** calling `nextDrawable` on the render thread paces an
  under-refresh workload to refresh/2; `maximumDrawableCount = 3` alone
  does not change this.
- **Fix:** move the present to a serial dispatch queue with a budget-2
  semaphore and a double-buffered IOSurface source; the main thread never
  waits on the compositor, and presents drop (never tear) when the
  compositor is two behind.
- **Result:** the 60 fps cap disappeared; early game reached the 120 Hz
  display limit; every battle cell crossed its 4× target. The pattern
  likely applies to any translation-layer present path on macOS.

### 4. Persistent-map upload rings sized for native completion latency  [upstream candidate]

- **Symptom:** ~10 ms/frame spinning in `glClientWaitSync` under
  `TransformsUploader::Update` (~30% of the main thread at 31 fps).
- **Cause:** upstream's triple-buffered persistent-mapped upload rings
  assume the GPU is ≤2 frames behind; a translation stack (Zink →
  KosmicKrisp → Metal) legitimately runs deeper. Compounding it, the fence
  wait loop used 1 ns `glClientWaitSync` timeouts — thousands of driver
  round-trips per frame on an unsignaled fence.
- **Fix:** ring depth is configurable and defaults to 6 on macOS
  (`SPRING_MAC_UPLOAD_BUFFERING`); the wait uses 250 µs blocking timeouts
  (semantically identical, driver-friendly). Kept as knobs deliberately —
  correct depths differ across Apple GPU tiers.
- **Result:** the uploader wait disappeared from profiles; part of the
  arena cell's climb past 4×.

### 5. Shader math mode: Metal's conservative default vs GL expectations

- **Symptom:** with everything above fixed, fragment work still dominated;
  the shader compiler reported 1,598 register-spill events in a 30 s trace.
- **Cause:** KosmicKrisp compiles MSL with `MTLMathModeSafe` + precise
  float functions — the right default for Vulkan conformance, but native
  GL drivers effectively run fast math, so GL content is tuned against
  that cost model.
- **Fix:** a driver knob (`KK_MATH_MODE=safe|relaxed|fast`, patch in
  `patches/mesa/`), defaulted to `fast` by the engine on macOS
  (user-overridable). **Shaders never feed the synced simulation**, so
  this cannot affect lockstep — rendering only.
- **Result:** arena 32.1 → 51.5 fps (+60%), screenshot-identical output.
  Final campaign numbers: 8.0× / 5.9× / 9.7× on the three battle cells.

## Determinism (the part that must never be exciting)

All simulation math is bit-identical to official builds — the full method,
test catalog, and limits live in [SYNC_VALIDATION.md](SYNC_VALIDATION.md).
Engine-side fixes that came out of that work, all latent-everywhere and
found on this port because a second compiler/architecture finally looked:

- **COB animation callins converted float → int16 through UB** — clang
  arm64 and gcc x86 disagree on out-of-range conversions; one unit's turret
  angle wrapping differently desynced a full 8v8 replay. Fixed with
  explicit range reduction.  [upstream candidate]
- **`math::floor` fleet parity** — x86 release builds reach `cvttss2si`
  semantics for out-of-range inputs; arm64 saturates differently. The port
  emulates the fleet's semantics in the one place it matters (PvE raptor
  waves found it).
- **gcc-only `-fsingle-precision-constant` in fleet builds** demotes FP
  literals inside streflop's double-precision libm; clang has no
  equivalent flag, so the shipping build swaps the affected object(s) with
  gcc-built ones and a 9-hash parity gate enforces it on every release
  build.
- Environment-gated `DumpState` (`SPRING_DUMP_STATE_RANGE=min:max`) for
  frame-exact desync bisection without a source edit.  [upstream candidate]

## Robustness fixes

- **Texture atlas:** `GetTexID()` null-guard + loud `Finalize()` failure
  logging (a failed projectile-atlas finalize was a silent null-deref).
- **LuaIntro re-enabled:** an early bring-up workaround skipped BAR's Lua
  intro, which silently skipped the game's config bootstrap
  (`MaxTextureAtlasSize`, tonemapping, deferred-rendering flags). The
  workaround outlived its cause; removed.
- **Audio:** recover from music-stream underrun (a stopped OpenAL source
  is not restarted by re-queuing buffers alone) and ignore capture-device
  hotplug churn (virtual loopback devices storming device-changed events
  crashed live games).  [upstream candidate]
- **Shutdown:** EGL context teardown is skipped at exit by default (a
  teardown race in the driver stack could abort the process on quit; the
  OS reclaims everything anyway). `SPRING_EGL_FULL_TEARDOWN=1` restores it
  for driver debugging.
- **Stall logger:** draw-gap events >150 ms land in the infolog (bounded:
  first 100, then every 100th), so freeze reports come with data attached.

## Driver patches (Mesa / Zink / KosmicKrisp)

Three small patches on a pinned upstream Mesa commit, shipped both as a
fork branch and as `patches/mesa/*.patch` so the driver is reproducible
from pure upstream source:

1. **Driver-identity log line** at instance creation (which dylib actually
   loaded — env-var-loaded driver stacks can silently fall back).
2. **`KK_MATH_MODE`** shader math-mode knob + `KK_COMPILE_LOG` slow-compile
   attribution (see §5).
3. **`ZINK_NO_TRIANGLE_FANS`** — let Zink lower fans itself when the
   driver's native fan path is disproportionately expensive.

KosmicKrisp moves fast upstream; this port pins the certified commit and
treats rebasing to current Mesa as a separate, re-certified event.

## Roadmap / open questions (help welcome)

- **True zero-copy present:** render the engine's FBO directly into the
  IOSurface Metal samples — no readback at all. Needs
  `VK_EXT_external_memory_metal` to grow IOSurface/MTLTexture handle
  support in KosmicKrisp and a Zink consumer for the resulting VkImage
  (~a month of focused upstream work by our estimate).
- **Late-game ceiling:** at ~44 fps late-game, the main thread spends
  ~38% in synced sim + game-Lua and ~21% in Lua widgets — the remaining
  wins are engine draw-thread decoupling or game-side, not driver-side.
  Profiles available on request.
- **KosmicKrisp `primitiveTopologyListRestart` cost cliff** (§1): whether
  advertising the feature is worth a 10–100× per-draw penalty for clients
  that leave restart enabled is a genuinely interesting upstream question,
  and the KK code comments show the authors anticipated exactly this
  client behavior. Data gladly shared.
