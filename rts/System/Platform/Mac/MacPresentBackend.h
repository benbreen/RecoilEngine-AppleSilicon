/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef MAC_PRESENT_BACKEND_H
#define MAC_PRESENT_BACKEND_H

#if defined(__APPLE__) && !defined(HEADLESS)

struct SDL_Window;

// macOS rendering backend. The engine renders through Mesa's surfaceless EGL
// (Zink -> KosmicKrisp -> Metal) into a pbuffer that acts as the GL default
// framebuffer; there is no window-system swapchain on the GL side, so every
// frame is read back and presented manually onto the window's CAMetalLayer
// (MetalPresent.mm). This module owns the EGL display/context/pbuffer
// lifecycle, the CAMetalLayer attachment, and the per-frame present path;
// CGlobalRendering calls in through this seam and stays platform-agnostic.
namespace MacPresent {
	// EGL bootstrap: display + pbuffer surface + GL context (compatibility
	// profile preferred), CAMetalLayer attach, Metal present init.
	// Call once, after the SDL window exists.
	bool CreateContext(SDL_Window* window);
	// Idempotent; skips actual EGL teardown by default (see implementation).
	void DestroyContext();
	void MakeCurrent(bool clear);
	// true between a successful CreateContext and DestroyContext
	bool ContextActive();

	// the EGL context handle (opaque; stored in CGlobalRendering::glContext)
	void* GetGLContext();
	// GL entry-point loader for gladLoadGLLoader (wraps eglGetProcAddress)
	typedef void* (*LoadProc)(const char* name);
	LoadProc GetGLLoadProc();

	// pbuffer (= GL default framebuffer) size in physical pixels
	void GetDrawableSize(int& w, int& h);
	// recreate the pbuffer at the window's current pixel size so resizes
	// render at true resolution; no-op when unchanged or before CreateContext
	void ResizeIfNeeded(SDL_Window* window);
	// NSWindow.backingScaleFactor, honoring SPRING_MAC_NO_RETINA (render at
	// logical 1x and let CoreAnimation upscale)
	double EffectiveBackingScale(SDL_Window* window);

	// read the default framebuffer back and present it onto the CAMetalLayer.
	// Returns false when the EGL context is not up — the caller falls back to
	// SDL_GL_SwapWindow.
	bool PresentFrame();

#ifdef SPRING_MAC_DIAGNOSTICS
	// SPRING_FRAME_CAPTURE: headless verification capture of the default FBO
	// (runs even when the actual present is suppressed)
	void DiagCaptureFrame();
	// SPRING_MAC_PRESENT_TEST: red/blue tracer-bullet flash via the Metal path
	void DiagRunPresentTest();
#endif
}

#endif // __APPLE__ && !HEADLESS

#endif // MAC_PRESENT_BACKEND_H
