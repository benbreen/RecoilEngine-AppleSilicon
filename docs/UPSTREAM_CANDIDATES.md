# Upstream candidates from the Phase C perf campaign (2026-07-11)

Everything below was found while taking BAR from 6.8 → 32+ fps (heavy cells)
on zink→KosmicKrisp→Metal, with identical rendering. Ordered by expected
upstream value.

## 1. Recoil engine PR: LuaVAO — enable GL_PRIMITIVE_RESTART only for strip/loop/fan modes
`engine-2025.06.24@65a1749c29` / `engine@f40af7ce50`.
LuaVAOImpl force-enables restart around every draw (incl. `Submit()` which is
hardcoded GL_TRIANGLES MDI) with restart index `0xffffff` for 32-bit buffers
(Lua 2^24 limit). On any Metal-backed GL stack this forces a per-draw compute
index-unroll (Metal only has fixed all-ones restart): 94% of BAR's draws paid
it → 6.8 fps. Restart is meaningless for list topologies unless the index
stream contains sentinels, which engine-fed meshes never do. Escape hatch:
`SPRING_LUAVAO_FORCE_RESTART=1`. Helps zink/ANGLE/Metal ports; no-op on
native desktop drivers.

## 2. Recoil engine PR: IStreamBuffer WaitBuffer — don't spin glClientWaitSync at 1ns
`WaitBuffer()` loops `glClientWaitSync(..., 1)` — thousands of driver
round-trips per frame when the fence isn't signaled. 250µs blocking waits are
semantically identical. Also: PERSISTENT_MAPPING_BUFFERING=3 assumes ≤2
frames of GPU completion latency; translation stacks (zink/KK) run deeper —
made configurable/6 on macOS.

## 3. KosmicKrisp: primitiveTopologyListRestart honesty vs cost
KK advertises `primitiveTopologyListRestart`, and honors it via a full
compute unroll + cross-queue pre_gfx ping-pong per draw batch. For apps that
"technically against spec" leave restart enabled on list draws (the code
comment already anticipates them), this is a 10-100× draw-cost cliff.
Consider: not advertising the feature (zink then filters restart on lists
itself), or a device-level opt-out. Data: BAR m7 arena 6.8→23.1 fps from
eliminating these unrolls.

## 4. Mesa st/readpixels + zink: GPU-pack path gaps (present-readback cliff)
- `st_ReadPixels`' "format matches → cheap memcpy fallback" maps a TILED
  resource on zink → staging blit queued behind the whole frame (~30ms in
  heavy scenes). The GPU-pack PBO path avoids it entirely but requires
  (a) a bound PIXEL_PACK buffer and (b) a non-swizzling format pair —
  BGRA read of RGBA8 fails `try_pbo_readpixels` (storage-image write in
  b8g8r8a8?) and silently falls back. Diagnosable only with driver prints
  (our `ST_DEBUG_READPIX`). A perf warning or a swizzle-capable pack shader
  would help every zink-on-Metal/portability consumer.
- zink: `ZINK_NO_TRIANGLE_FANS` env (our patch) — lets zink convert fans
  even when the driver claims support; useful when driver-side conversion
  is disproportionately expensive (KK compute unroll).

## 5. CAMetalLayer nextDrawable pacing (documentation/sample-code worthy)
Calling `nextDrawable` on the render thread paced an under-refresh workload
to exactly refresh/2 (60 on a 120Hz panel), blocking ~12ms/frame;
`maximumDrawableCount=3` did not change it. Moving present to a serial
dispatch queue with a budget-2 semaphore + double-buffered IOSurface source
restored full-rate presentation. Pattern likely affects any GL-translation
present path that reads back and re-presents.

## Added 2026-07-11 (review-hardening pass)

### 6. Recoil engine PR: float→short / float→int UB fixes in synced code
`engine-2025.06.24@39be48f839` (COB callins; found by live desync clang-arm64
vs gcc-x86) + the audit sweep of the same class (IPathController,
Ground/HoverAirMoveType direct-control heading, LuaSyncedMoveCtrl.SetHeading,
LuaSyncedRead.GetFacingFromHeading). Out-of-range float→short is UB; the two
fleet compilers disagree. Defined int32 truncation, gcc-x86-identical.
Full register: engine SYNC_VALIDATION.md Appendix A.

### 7. Recoil engine PR: streflop math::floor — x86 cvttss2si semantics on arm64
`engine-2025.06.24@4a01bf411f`. Out-of-range float→int is UB; x86 saturates
to 0x80000000 and game code observes it (raptors desync). Emulate on arm64.

### 8. Recoil engine PR: SDL_AUDIODEVICEADDED passes a device index, not an instance id
`fd63d525d8` subset. The handler compared an index against instance ids and
tore down a working device on hot-plug ADDED events (macOS device-churn crash
storm). Platform-independent bug.

### 9. Recoil engine PR: don't terminate on joinable ext threads at fatal-path exit
`fd63d525d8` subset. ExitSpringProcess calls exit() off-main, bypassing
ClearExtJobs; static destruction of a joinable std::thread is terminate().
Detach leftovers in the container's destructor; guard the join.

### 10. Recoil engine PR: configurable WindowTitle ({version} placeholder)
`816e1cbf3d`. Lets a game distribution brand the window without forking the
engine; default title unchanged.
