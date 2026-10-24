/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "MacPresentBackend.h"

#if defined(__APPLE__) && !defined(HEADLESS)

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsTypes.h> // kDisplayModeNativeFlag

#include <EGL/egl.h>
#include <SDL.h>
#include <SDL_syswm.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h> // getpagesize (direct-present ring alignment)

#include "MetalPresent.h"
// glad directly, not Rendering/GL/myGL.h: myGL pulls the engine math stack
// (float3 -> SpringMath -> streflop/sse2neon), which is neither needed here
// nor compatible with this Objective-C++ TU
#include <glad/glad.h>
#include "System/Config/ConfigHandler.h"
#include "System/Log/ILog.h"
#include "System/Misc/SpringTime.h"
#include "System/TimeProfiler.h"

// SPRING_MAC_DIAGNOSTICS compiles in the heavier macOS diagnostics (headless
// frame capture, per-frame present timing, raw-frame dumps, the present
// tracer bullet, and the step-by-step bootstrap tracing below). Release
// builds carry none of that code. Configure with cmake -DSPRING_MAC_DIAGNOSTICS=ON.
#ifdef SPRING_MAC_DIAGNOSTICS
#define MAC_DLOG(...) fprintf(stderr, __VA_ARGS__)
#else
#define MAC_DLOG(...) ((void)0)
#endif

CONFIG(int, MacPresentDirect).defaultValue(1).minimumValue(0).maximumValue(1).description("macOS: present shader reads the readback ring directly from unified memory (0 = IOSurface staging path). Runtime-changeable so perf A/B legs can share one seeked process.");
CONFIG(float, MacRenderScale).defaultValue(1.0f).minimumValue(0.5f).maximumValue(1.0f).description("macOS: fraction of the window's pixel resolution the game renders at (0.5-1.0). Below 1.0 the frame is upscaled to the window at present time (see MacUpscaler). Lower = faster readback and rendering. Applied at startup and on window resize.");
CONFIG(int, MacUpscaler).defaultValue(1).minimumValue(0).maximumValue(1).description("macOS: how a frame rendered below window resolution is upscaled. 0 = plain stretch, 1 = MetalFX spatial upscaler (falls back to plain stretch if unavailable). Runtime-changeable.");

// A truly zero-copy present (render the engine FBO directly into the
// IOSurface that Metal samples — no readback at all) is blocked on Mesa
// upstream work: KosmicKrisp's VK_EXT_external_memory_metal needs to grow
// IOSurface/MTLTexture handle support (today it only handles MTLHeap), and
// Zink needs a new MESA_memory_object_metal GL extension to consume the
// resulting VkImage as a GL FBO color attachment. Estimated ~1 month of
// focused upstream work — see IMPROVEMENTS.md for the roadmap.

namespace {

EGLDisplay eglDpy = EGL_NO_DISPLAY;
EGLContext eglCtx = EGL_NO_CONTEXT;
EGLSurface eglSfc = EGL_NO_SURFACE;
EGLConfig  eglCfg = nullptr;  // saved so the pbuffer can be recreated on resize
void*      metalLayer = nullptr; // CAMetalLayer attached to the window's NSView
int        pbufW = 1280;         // pbuffer (default framebuffer) dimensions
int        pbufH = 720;
std::vector<unsigned char> presentBuf; // reused glReadPixels staging buffer

// BENCHMARK PIN (perf-test only): SPRING_MAC_PERF_RENDER_SIZE=<W>x<H> forces
// the render target to a fixed pixel count, independent of window size,
// backing scale, panel geometry and GPU core count. Parsed once — it is read
// from BOTH the initial pbuffer sizing and ResizeIfNeeded, which must agree or
// a stray resize would silently un-pin the benchmark mid-run. Returns false
// (leaving w/h untouched) when unset or malformed. See the long comment at the
// CreateContext call site for what each coupling is and why it matters.
bool PerfPinnedRenderSize(int& w, int& h)
{
	static int  s_w = 0, s_h = 0;
	static bool s_parsed = false;
	if (!s_parsed) {
		s_parsed = true;
		if (const char* rs = getenv("SPRING_MAC_PERF_RENDER_SIZE")) {
			int rw = 0, rh = 0;
			if (sscanf(rs, "%dx%d", &rw, &rh) == 2 && rw > 0 && rh > 0) {
				s_w = rw;
				s_h = rh;
			} else {
				LOG_L(L_ERROR, "[EGL] SPRING_MAC_PERF_RENDER_SIZE=\"%s\" is malformed "
				               "(want <W>x<H>, e.g. 2560x1440) — ignoring", rs);
			}
		}
	}
	if (s_w <= 0 || s_h <= 0)
		return false;
	w = s_w;
	h = s_h;
	return true;
}

// MacPresentDirect config value, mirrored here so the present path does not
// query the config map every frame; the observer registered in CreateContext
// keeps it current (config changes still apply mid-run, which the perf
// harness relies on for phased A/B legs).
std::atomic<int> presentDirect = {1};

// MacUpscaler as configured, and whether the current render size was derived
// with MacRenderScale < 1 (set by EffectiveBackingScale). MetalFX is engaged
// only for a user-requested render scale: frames that are smaller than the
// drawable for other reasons (SPRING_MAC_NO_RETINA, the hardware caps in
// HardwareBackingScale) keep upstream's plain stretch, so MacRenderScale=1
// presents exactly as before.
std::atomic<int>  upscalerCfg  = {1};
std::atomic<bool> renderScaled = {false};

void ApplyUpscaler()
{
	MacMetalPresent_SetUpscaler(renderScaled.load(std::memory_order_relaxed) ? upscalerCfg.load(std::memory_order_relaxed) : 0);
}

struct PresentDirectObserver {
	void ConfigNotify(const std::string& key, const std::string& value) {
		if (key == "MacUpscaler") {
			upscalerCfg.store(atoi(value.c_str()), std::memory_order_relaxed);
			ApplyUpscaler();
			return;
		}
		presentDirect.store(atoi(value.c_str()), std::memory_order_relaxed);
	}
};
PresentDirectObserver presentDirectObserver;

// Pipelined readback depth: frames of present latency between the GPU pack
// of a frame and its present. 2 is the certified default (IMPROVEMENTS.md);
// diagnostics builds can override it (SPRING_MAC_PRESENT_LAG=0..3, 0 =
// synchronous readback of the current frame: zero added latency, stalls
// until the GPU drains — a latency-debugging tool). Likewise the GPU-pack
// ring can only be disabled (SPRING_MAC_PRESENT_GPUPACK=0, falling back to
// the staging ring) in diagnostics builds.
#ifdef SPRING_MAC_DIAGNOSTICS
const int presentLagFrames = []() -> int {
	if (const char* s = getenv("SPRING_MAC_PRESENT_LAG")) {
		const int v = atoi(s);
		if (v >= 0 && v <= 3) return v; // 3 needs the gpu-pack ring (PP_RING=4)
	}
	return 2;
}();
const bool useGpuPackRing = []() {
	const char* s = getenv("SPRING_MAC_PRESENT_GPUPACK");
	return s == nullptr || atoi(s) != 0;
}();
#else
constexpr int  presentLagFrames = 2;
constexpr bool useGpuPackRing   = true;
#endif

// Attach a CAMetalLayer to the SDL window's content view (before EGL sees
// the window — prevents crashes in wsi_metal_layer_size) and return it for
// the manual present path. Falls back to returning the bare view when the
// layer cannot be created. MRC rules: +layer is autoreleased; the view
// retains it via setLayer: and both live for the process lifetime.
void* AttachMetalLayer(SDL_Window* window)
{
	SDL_SysWMinfo info;
	SDL_VERSION(&info.version);
	if (!SDL_GetWindowWMInfo(window, &info))
		return nullptr;

	NSWindow* nswindow = (NSWindow*)info.info.cocoa.window;
	NSView* view = [nswindow contentView];
	if (view != nil) {
		[view setWantsLayer:YES];

		CAMetalLayer* layer = [CAMetalLayer layer];
		if (layer != nil) {
			[layer setFrame:[view bounds]];
			[layer setOpaque:YES];

			NSWindow* win = [view window];
			if (win != nil)
				[layer setContentsScale:[win backingScaleFactor]];

			[view setLayer:layer];
			return (void*)layer;
		}
	}
	return (void*)view;
}

NSWindow* NSWindowFor(SDL_Window* window)
{
	SDL_SysWMinfo wmInfo;
	SDL_VERSION(&wmInfo.version);
	if (!SDL_GetWindowWMInfo(window, &wmInfo))
		return nil;

	return (NSWindow*)wmInfo.info.cocoa.window;
}

// NSWindow.backingScaleFactor (1.0 on non-Retina, 2.0 on standard Retina).
// Used to size the pbuffer (= GL default framebuffer) in physical pixels so
// full-resolution rendering isn't clipped.
double BackingScaleFactor(SDL_Window* window)
{
	NSWindow* nswindow = NSWindowFor(window);
	if (nswindow == nil)
		return 1.0;

	const double scale = [nswindow backingScaleFactor];
	return (scale > 0.0) ? scale : 1.0;
}

// Physical panel resolution of the given screen's display: the largest mode
// carrying kDisplayModeNativeFlag. NB "largest mode overall" over-reports —
// macOS synthesizes supersampled scaled modes bigger than the panel (e.g.
// 7680x3240 on a 5120x2160 panel). Cached per display id; mode enumeration
// is not free and this runs on every window resize.
bool NativePanelPixels(NSScreen* screen, double& outW, double& outH)
{
	outW = 0.0;
	outH = 0.0;

	if (screen == nil)
		return false;

	NSNumber* num = [screen deviceDescription][@"NSScreenNumber"];
	if (num == nil)
		return false;

	const CGDirectDisplayID did = (CGDirectDisplayID)[num unsignedIntValue];

	static CGDirectDisplayID cachedId = kCGNullDirectDisplay;
	static double cachedW = 0.0;
	static double cachedH = 0.0;

	if (did != cachedId) {
		double bestW = 0.0;
		double bestH = 0.0;

		CFStringRef optKey = kCGDisplayShowDuplicateLowResolutionModes;
		CFDictionaryRef opts = CFDictionaryCreate(nullptr,
				(const void**)&optKey, (const void**)&kCFBooleanTrue, 1,
				&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, opts);
		if (opts != nullptr)
			CFRelease(opts);

		if (modes != nullptr) {
			for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
				CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
				if ((CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag) == 0)
					continue;
				const double w = (double)CGDisplayModeGetPixelWidth(m);
				const double h = (double)CGDisplayModeGetPixelHeight(m);
				if (w * h > bestW * bestH) {
					bestW = w;
					bestH = h;
				}
			}
			CFRelease(modes);
		}

		cachedId = did;
		cachedW = bestW;
		cachedH = bestH;
	}

	outW = cachedW;
	outH = cachedH;
	return (cachedW > 0.0 && cachedH > 0.0);
}

// Apple-GPU core count from the IORegistry ("gpu-core-count" on the
// IOAccelerator node); 0 when unavailable. Used only to size the default
// render-resolution budget below.
int GpuCoreCount()
{
	static int cached = -1;
	if (cached >= 0)
		return cached;

	cached = 0;

	io_iterator_t it = IO_OBJECT_NULL;
	if (IOServiceGetMatchingServices(MACH_PORT_NULL, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS) {
		io_object_t obj = IO_OBJECT_NULL;
		while ((obj = IOIteratorNext(it)) != IO_OBJECT_NULL) {
			CFTypeRef v = IORegistryEntrySearchCFProperty(obj, kIOServicePlane, CFSTR("gpu-core-count"),
					kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
			if (v != nullptr) {
				if (CFGetTypeID(v) == CFNumberGetTypeID()) {
					int n = 0;
					CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
					cached = std::max(cached, n);
				}
				CFRelease(v);
			}
			IOObjectRelease(obj);
		}
		IOObjectRelease(it);
	}

	return cached;
}

} // anonymous namespace


namespace MacPresent {

void CaptureBootDisplayModes(); // defined below (boot display-mode snapshot)

bool CreateContext(SDL_Window* window)
{
	// Default the KosmicKrisp Metal shader compiler to fast math (what native
	// GL drivers effectively run). Safe+Precise (KK's Vulkan-conformance
	// default) inflates ALU and register pressure — measured 1598 shader
	// spill events and 32→51.5 fps on the m7 arena from this alone.
	// Overridable: export KK_MATH_MODE=safe|relaxed|fast before launch.
	setenv("KK_MATH_MODE", "fast", 0); // 0 = don't overwrite user's value

	// remember every display's boot mode for RestoreDesktopDisplayMode
	CaptureBootDisplayModes();

	MAC_DLOG("[EGL] eglGetDisplay(EGL_DEFAULT_DISPLAY)...\n");
	eglDpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	MAC_DLOG("[EGL] eglGetDisplay -> %p (lastError=0x%x)\n", (void*)eglDpy, eglGetError());
	if (eglDpy == EGL_NO_DISPLAY) return false;

	EGLint eglMajor = 0, eglMinor = 0;
	EGLBoolean initOk = eglInitialize(eglDpy, &eglMajor, &eglMinor);
	MAC_DLOG("[EGL] eglInitialize -> %d (version %d.%d, lastError=0x%x)\n",
			(int)initOk, eglMajor, eglMinor, eglGetError());
	if (!initOk) return false;

	const char* vendor   = eglQueryString(eglDpy, EGL_VENDOR);
	const char* version  = eglQueryString(eglDpy, EGL_VERSION);
	const char* clientApis = eglQueryString(eglDpy, EGL_CLIENT_APIS);
	MAC_DLOG("[EGL] vendor=%s version=%s clientApis=%s\n",
			vendor ? vendor : "?", version ? version : "?", clientApis ? clientApis : "?");

	EGLBoolean bindOk = eglBindAPI(EGL_OPENGL_API);
	MAC_DLOG("[EGL] eglBindAPI(EGL_OPENGL_API) -> %d (lastError=0x%x)\n",
			(int)bindOk, eglGetError());

	// On macOS with Mesa-surfaceless EGL, EGL_WINDOW_BIT is unsupported.
	// The actual presentation happens via the CAMetalLayer + KosmicKrisp WSI
	// (Vulkan -> Metal), so we only need a pbuffer-capable config here.
	EGLint configAttribs[] = {
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_NONE
	};
	EGLConfig chosenConfig;
	EGLint numConfigs = 0;
	EGLBoolean cfgOk = eglChooseConfig(eglDpy, configAttribs, &chosenConfig, 1, &numConfigs);
	MAC_DLOG("[EGL] eglChooseConfig -> %d (numConfigs=%d, lastError=0x%x)\n",
			(int)cfgOk, numConfigs, eglGetError());
	if (!cfgOk || numConfigs == 0)
		return false;
	eglCfg = chosenConfig; // remember for pbuffer recreation on window resize

	void* nativeView = AttachMetalLayer(window);
	metalLayer = nativeView; // CAMetalLayer for the manual present path

	// Size the pbuffer (= the GL default framebuffer) to the window's *backing*
	// pixel size, so the engine's full-resolution (Retina) rendering isn't
	// clipped. SDL_GetWindowSizeInPixels returns logical points on this
	// surfaceless/borderless setup, so compute backing pixels explicitly via
	// the window size in points * backingScaleFactor. The manual Metal present
	// reads this whole buffer back each SwapBuffers.
	//
	// glReadPixels of the full Retina pbuffer is the
	// dominant per-frame cost (measured 40-55ms at 2944x1908). The Metal
	// present pass linear-samples the IOSurface into the drawable, so we can
	// render at logical (1x) resolution and let CoreAnimation upscale to
	// Retina with negligible cost — at ~4x less readback data. Opt in with
	// SPRING_MAC_NO_RETINA=1.
	int winW = 0, winH = 0;
	SDL_GetWindowSize(window, &winW, &winH);
	const double bsfTrue   = BackingScaleFactor(window);
	const bool   noRetina  = (getenv("SPRING_MAC_NO_RETINA") != nullptr);
	// backing scale with the hardware-aware default-resolution caps
	// (panel-native + GPU pixel budget) applied; see EffectiveBackingScale
	const double bsf       = EffectiveBackingScale(window);
	int pxW = (int)(winW * bsf + 0.5);
	int pxH = (int)(winH * bsf + 0.5);
	if (pxW <= 0 || pxH <= 0) { pxW = 1280; pxH = 720; }

	// ---- BENCHMARK PIN: SPRING_MAC_PERF_RENDER_SIZE=<W>x<H> ------------------
	// Perf-test only. Everything above derives the render resolution from the
	// hardware, through FOUR separate couplings, so the "same" benchmark is a
	// different workload on every setup (all measured 2026-08-07):
	//   1. the window itself is clamped to fit the screen — a 1920x1080 pin
	//      actually got 1873x1018 on a 1920x1080 panel (menu bar + title bar);
	//   2. bsf is the monitor's backing scale (1x here, 2x on the Dell = 4x
	//      the pixels for an identical command line);
	//   3. EffectiveBackingScale's panel-native cap keys off the desktop being
	//      a scaled mode;
	//   4. its GPU pixel budget keys off GPU CORE COUNT (60 cores -> 36 MP and
	//      never caps; a 10-core Air -> 6 MP and does).
	// Overriding pbuf directly bypasses all four at once. This is the same
	// mechanism SPRING_MAC_NO_RETINA already relies on — the Metal present pass
	// linear-samples the source into the drawable, so a render target that does
	// not match the window is scaled at present time (up or down) for free.
	// GetDrawableSize() returns pbufW/pbufH, so the engine's viewport and FBO
	// follow this automatically and stay consistent.
	const bool perfSize = PerfPinnedRenderSize(pxW, pxH);

	pbufW = pxW;
	pbufH = pxH;
	LOG("[EGL] window %dx%d pts * %.2f scale -> pbuffer %dx%d px%s%s",
			winW, winH, bsf, pxW, pxH,
			noRetina ? " (SPRING_MAC_NO_RETINA=1)" : "",
			perfSize ? " (SPRING_MAC_PERF_RENDER_SIZE — hardware-independent)" : "");
	if (noRetina)
		LOG("[EGL] true backing scale=%.2f; CoreAnimation will upscale", bsfTrue);
	if (perfSize)
		LOG("[EGL] perf pin: render %dx%d = %.2f MP, independent of window (%dx%d pt), "
		    "backing scale (%.2f), panel and GPU core count",
		    pxW, pxH, (pxW * (double)pxH) / 1.0e6, winW, winH, bsfTrue);

	if (nativeView) {
		eglSfc = eglCreateWindowSurface(eglDpy, chosenConfig, (EGLNativeWindowType)nativeView, NULL);
	}
	if (eglSfc == EGL_NO_SURFACE) {
		EGLint pbAttribs[] = { EGL_WIDTH, pbufW, EGL_HEIGHT, pbufH, EGL_NONE };
		eglSfc = eglCreatePbufferSurface(eglDpy, chosenConfig, pbAttribs);
		if (eglSfc == EGL_NO_SURFACE) return false;
		MAC_DLOG("[EGL] FALLBACK to PbufferSurface %dx%d surface=%p\n", pbufW, pbufH, (void*)eglSfc);
	}

	// Dump what the chosen config actually supports.
	{
		EGLint cfgRenderable = 0, cfgSurface = 0, cfgConformant = 0;
		eglGetConfigAttrib(eglDpy, chosenConfig, EGL_RENDERABLE_TYPE, &cfgRenderable);
		eglGetConfigAttrib(eglDpy, chosenConfig, EGL_SURFACE_TYPE, &cfgSurface);
		eglGetConfigAttrib(eglDpy, chosenConfig, EGL_CONFORMANT, &cfgConformant);
		MAC_DLOG("[EGL] Config: renderable=0x%x surfaceType=0x%x conformant=0x%x (OPENGL_BIT=0x%x)\n",
				cfgRenderable, cfgSurface, cfgConformant, EGL_OPENGL_BIT);
	}
	// Prefer a COMPATIBILITY-profile context. Mesa 26.2 Zink grants GL 4.6
	// compat on KosmicKrisp (verified: "4.6 (Compatibility Profile)"), which is
	// a strict superset of core: it keeps all modern GL4 features AND the legacy
	// paths BAR pervasively relies on (immediate mode / glBegin, display lists,
	// the fixed-function matrix stack, and '#version ... compatibility' GLSL).
	// This eliminates an otherwise huge per-shader core-profile port. We fall
	// back to a CORE context if compat is refused, or if SPRING_MAC_GL_CORE is
	// set to force the old behavior.
	//
	// Note: geometry shaders are unavailable regardless of profile because
	// KosmicKrisp's Vulkan reports geometryShader=false (Metal has no GS stage);
	// that is a separate problem from the GL profile.
	struct GLVersion { EGLint major, minor; };
	const GLVersion tryVersions[] = {
		{4,6},{4,5},{4,4},{4,3},{4,2},{4,1},{4,0},{3,3},{3,2}
	};
	const bool forceCore = (getenv("SPRING_MAC_GL_CORE") != nullptr);

	if (!forceCore) {
		EGLint compatAttribs[] = {
			EGL_CONTEXT_MAJOR_VERSION, 0,
			EGL_CONTEXT_MINOR_VERSION, 0,
			EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT,
			EGL_NONE
		};
		for (const auto& v : tryVersions) {
			compatAttribs[1] = v.major;
			compatAttribs[3] = v.minor;
			eglCtx = eglCreateContext(eglDpy, chosenConfig, EGL_NO_CONTEXT, compatAttribs);
			EGLint err = eglGetError();
			MAC_DLOG("[EGL] eglCreateContext(%d.%d COMPAT) -> %p (lastError=0x%x)\n",
					(int)v.major, (int)v.minor, (void*)eglCtx, err);
			if (eglCtx != EGL_NO_CONTEXT)
				break;
		}
		LOG("%s", eglCtx != EGL_NO_CONTEXT
			? "[EGL] COMPAT profile context obtained."
			: "[EGL] COMPAT profile unavailable; falling back to CORE.");
	}

	EGLint contextAttribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 0,
		EGL_CONTEXT_MINOR_VERSION, 0,
		EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
		EGL_NONE
	};
	for (const auto& v : tryVersions) {
		if (eglCtx != EGL_NO_CONTEXT)
			break;
		contextAttribs[1] = v.major;
		contextAttribs[3] = v.minor;
		eglCtx = eglCreateContext(eglDpy, chosenConfig, EGL_NO_CONTEXT, contextAttribs);
		EGLint err = eglGetError();
		MAC_DLOG("[EGL] eglCreateContext(%d.%d core) -> %p (lastError=0x%x)\n",
				(int)v.major, (int)v.minor, (void*)eglCtx, err);
		if (eglCtx != EGL_NO_CONTEXT)
			break;
	}
	if (eglCtx == EGL_NO_CONTEXT) return false;

	EGLBoolean mcOk = eglMakeCurrent(eglDpy, eglSfc, eglSfc, eglCtx);
	MAC_DLOG("[EGL] eglMakeCurrent -> %d (lastError=0x%x)\n", (int)mcOk, eglGetError());
	if (!mcOk)
		return false;

#ifdef SPRING_MAC_DIAGNOSTICS
	// Probe GL via eglGetProcAddress before the engine's glad pass runs.
	// Using raw types because glad has not been loaded at this point.
	typedef const unsigned char* (*PFN_glGetString)(unsigned int);
	auto p_glGetString = (PFN_glGetString)eglGetProcAddress("glGetString");
	if (p_glGetString) {
		const char* glVer    = (const char*)p_glGetString(0x1F02u);  // GL_VERSION
		const char* glVendor = (const char*)p_glGetString(0x1F00u);  // GL_VENDOR
		const char* glRend   = (const char*)p_glGetString(0x1F01u);  // GL_RENDERER
		const char* glsl     = (const char*)p_glGetString(0x8B8Cu);  // GL_SHADING_LANGUAGE_VERSION
		MAC_DLOG("[EGL/GL] vendor='%s'\n",   glVendor ? glVendor : "(null)");
		MAC_DLOG("[EGL/GL] renderer='%s'\n", glRend   ? glRend   : "(null)");
		MAC_DLOG("[EGL/GL] version='%s'\n",  glVer    ? glVer    : "(null)");
		MAC_DLOG("[EGL/GL] glsl='%s'\n",     glsl     ? glsl     : "(null)");
	} else {
		MAC_DLOG("[EGL/GL] eglGetProcAddress(glGetString) returned NULL\n");
	}
#endif

	// Mirror the MacPresentDirect config into the present path's atomic and
	// keep it current through a config observer, instead of a per-frame
	// config-map query in PresentFrame (the callback fires on the main
	// thread from ConfigHandler::Update, so mid-run flips still apply).
	if (configHandler != nullptr) {
		presentDirect.store(configHandler->GetInt("MacPresentDirect"), std::memory_order_relaxed);
		upscalerCfg.store(configHandler->GetInt("MacUpscaler"), std::memory_order_relaxed);
		ApplyUpscaler();
		configHandler->NotifyOnChange(&presentDirectObserver, {"MacPresentDirect", "MacUpscaler"});
	}

	// Set up the manual present path now that the layer + context exist.
	if (!MacMetalPresent_Init(metalLayer))
		LOG_L(L_ERROR, "[EGL] MacMetalPresent_Init failed; window will not show frames");

	return true;
}

void DestroyContext()
{
	if (eglDpy != EGL_NO_DISPLAY) {
		eglMakeCurrent(eglDpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		// Actually destroying the context at process exit is racy in the
		// Zink->KosmicKrisp stack: zink_context_destroy -> vkQueueWaitIdle
		// submits a signal event to a Metal command buffer that may already
		// be tearing down, Metal raises an NSException, and the process dies
		// with SIGABRT (reproduced after long GUI sessions). We are exiting
		// anyway — the OS reclaims the GPU objects — so skip the destruction
		// ("fast exit"). Set SPRING_EGL_FULL_TEARDOWN=1 to restore it when
		// debugging the driver race itself.
		if (getenv("SPRING_EGL_FULL_TEARDOWN") != nullptr) {
			if (eglCtx != EGL_NO_CONTEXT) eglDestroyContext(eglDpy, eglCtx);
			if (eglSfc != EGL_NO_SURFACE) eglDestroySurface(eglDpy, eglSfc);
			eglTerminate(eglDpy);
		}
	}
	eglDpy = EGL_NO_DISPLAY;
	eglCtx = EGL_NO_CONTEXT;
	eglSfc = EGL_NO_SURFACE;
}

void MakeCurrent(bool clear)
{
	if (clear)
		eglMakeCurrent(eglDpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	else
		eglMakeCurrent(eglDpy, eglSfc, eglSfc, eglCtx);
}

bool ContextActive()
{
	return (eglDpy != EGL_NO_DISPLAY && eglSfc != EGL_NO_SURFACE);
}

void* GetGLContext()
{
	return (void*)eglCtx;
}

LoadProc GetGLLoadProc()
{
	return (LoadProc)&eglGetProcAddress;
}

void GetDrawableSize(int& w, int& h)
{
	w = pbufW;
	h = pbufH;
}

// Effective render scale = NSWindow.backingScaleFactor with two
// hardware-aware caps, so the DEFAULT render resolution is sensible on any
// machine without touching (or ever overriding) the user's configured
// window size/resolution — those are in points and stay fully honored;
// only the default-framebuffer pixel density changes.
//
// Cap 1 — never render more pixels than the physical panel can display.
// macOS "scaled" desktop modes back the desktop with MORE pixels than the
// panel has (M2 Air 13.6" default "looks like 1470x956" = 2940x1912 backing
// on a 2560x1664 panel = +31% pixels) and the window server downsamples.
// Rendering at that oversized backing burns GPU fragment/bandwidth time on
// pixels that never reach the screen — capping to the panel ratio is
// fidelity-neutral by construction.
//
// Cap 2 — pixel budget for small GPUs driving large displays (e.g. an Air
// on a 5K monitor): the default framebuffer is kept within ~0.6 MPixels per
// Apple-GPU core (M2 Air, 10 cores -> 6.0 MP: its own 4.3 MP panel is
// unaffected, a 14.7 MP 5K desktop is capped; M2 Ultra, 60 cores -> 36 MP:
// never capped). Skipped when the core count cannot be read.
//
// Never drops below 1.0 (logical resolution). Overrides:
//   SPRING_MAC_NO_RETINA=1    force 1x rendering (strongest, pre-existing)
//   SPRING_MAC_FULL_BACKING=1 disable both caps (raw backing scale, i.e.
//                             deliberate supersampling on scaled desktops)
static double HardwareBackingScale(SDL_Window* window);

// MacRenderScale: user-chosen fraction of the hardware-derived resolution.
// The Metal present pass upscales the smaller frame to the drawable (MetalFX
// spatial when MacUpscaler=1), and every pixel not rendered is also a pixel
// not read back — the readback is the dominant per-frame cost on this port.
double EffectiveBackingScale(SDL_Window* window)
{
	const double hw = HardwareBackingScale(window);
	if (configHandler == nullptr)
		return hw;

	const double rs = std::clamp(double(configHandler->GetFloat("MacRenderScale")), 0.5, 1.0);
	renderScaled.store(rs < 1.0, std::memory_order_relaxed);
	ApplyUpscaler();
	if (rs < 1.0) {
		static double loggedRs = -1.0;
		if (std::fabs(rs - loggedRs) > 1e-3) {
			loggedRs = rs;
			LOG("[EGL] MacRenderScale %.2f -> render scale %.3f (hardware %.3f)", rs, hw * rs, hw);
		}
	}
	return hw * rs;
}

static double HardwareBackingScale(SDL_Window* window)
{
	if (getenv("SPRING_MAC_NO_RETINA") != nullptr)
		return 1.0;

	const double bsf = BackingScaleFactor(window);

	if (getenv("SPRING_MAC_FULL_BACKING") != nullptr)
		return bsf;

	double scale = bsf;
	const char* capReason = "";

	NSWindow* nswindow = NSWindowFor(window);
	NSScreen* screen = (nswindow != nil) ? [nswindow screen] : nil;
	if (screen == nil)
		screen = [NSScreen mainScreen];

	// cap 1: panel-native
	double panelW = 0.0;
	double panelH = 0.0;
	const NSSize desktopPts = (screen != nil) ? [screen frame].size : NSMakeSize(0.0, 0.0);
	if (NativePanelPixels(screen, panelW, panelH) && desktopPts.width > 0.0 && desktopPts.height > 0.0) {
		const double panelScale = std::min(panelW / desktopPts.width, panelH / desktopPts.height);
		if (panelScale < scale) {
			scale = panelScale;
			capReason = " — capped to panel-native (scaled desktop backing > panel)";
		}
	}

	// cap 2: GPU pixel budget (applies to the actual window area in points)
	const int gpuCores = GpuCoreCount();
	int winW = 0;
	int winH = 0;
	SDL_GetWindowSize(window, &winW, &winH);
	if (gpuCores > 0 && winW > 0 && winH > 0) {
		const double budgetPx = double(gpuCores) * 600.0e3;
		if (double(winW) * double(winH) * scale * scale > budgetPx) {
			scale = std::sqrt(budgetPx / (double(winW) * double(winH)));
			capReason = " — capped by GPU pixel budget (small GPU, large display)";
		}
	}

	scale = std::clamp(scale, std::min(1.0, bsf), bsf);

	static double loggedScale = -1.0;
	if (std::fabs(scale - loggedScale) > 1e-3) {
		loggedScale = scale;
		LOG("[EGL] effective backing scale %.3f (raw %.2f, window %dx%d pt, desktop %.0fx%.0f pt, panel %.0fx%.0f px, %d GPU cores)%s",
				scale, bsf, winW, winH,
				(double)desktopPts.width, (double)desktopPts.height,
				panelW, panelH, gpuCores, capReason);
	}

	return scale;
}

// Boot ("desktop") display modes, captured once at CreateContext — the game
// always boots with every display at the user's configured mode. Used to put
// a single display back after exclusive fullscreen strands it in a lowered
// mode. NB: CGRestorePermanentDisplayConfiguration was tried first and is the
// WRONG hammer — it reconfigures every display and relocated the game window
// onto the secondary (virtual) display, violating display preservation.
static std::vector<std::pair<CGDirectDisplayID, CGDisplayModeRef>> s_bootDisplayModes;

void CaptureBootDisplayModes()
{
	if (!s_bootDisplayModes.empty())
		return;
	CGDirectDisplayID ids[16];
	uint32_t cnt = 0;
	if (CGGetActiveDisplayList(16, ids, &cnt) != kCGErrorSuccess)
		return;
	for (uint32_t i = 0; i < cnt; i++) {
		CGDisplayModeRef m = CGDisplayCopyDisplayMode(ids[i]); // retained
		if (m != nullptr)
			s_bootDisplayModes.emplace_back(ids[i], m);
	}
}

// See MacPresentBackend.h. Leaving SDL exclusive fullscreen does not reliably
// restore the lowered display mode on this stack (observed: display stuck at
// 1920x1080 for 12+ s after SDL_SetWindowFullscreen(window, 0); no window
// event fires, so nothing downstream corrects it either). When the engine
// switches to any NON-exclusive mode, compare the window's display point
// size against the expected desktop size and — on mismatch — set THAT
// display back to its boot mode (per-display, no global reconfiguration).
void RestoreDesktopDisplayMode(SDL_Window* window, int desktopW, int desktopH)
{
	if (desktopW <= 0 || desktopH <= 0)
		return;

	NSWindow* nswindow = NSWindowFor(window);
	NSScreen* screen = (nswindow != nil) ? [nswindow screen] : nil;
	if (screen == nil)
		screen = [NSScreen mainScreen];
	if (screen == nil)
		return;

	const NSSize cur = [screen frame].size;
	if ((int)std::lround(cur.width) == desktopW && (int)std::lround(cur.height) == desktopH)
		return;

	NSNumber* num = [screen deviceDescription][@"NSScreenNumber"];
	if (num == nil)
		return;
	const CGDirectDisplayID did = (CGDirectDisplayID)[num unsignedIntValue];

	for (const auto& [bootDid, bootMode] : s_bootDisplayModes) {
		if (bootDid != did)
			continue;
		LOG("[EGL] display %u at %.0fx%.0f pt != desktop %dx%d pt after leaving exclusive fullscreen — restoring its boot mode",
				did, cur.width, cur.height, desktopW, desktopH);
		CGDisplaySetDisplayMode(did, bootMode, nullptr);
		return;
	}
}

// See MacPresentBackend.h. Ensures BAR's "windowed fullscreen" (desktop-sized
// borderless window) truly covers the whole screen: Cocoa places/zooms
// normal-level windows within the visibleFrame (menu bar + Dock excluded;
// SDL_MaximizeWindow = [NSWindow zoom:] does the same), which exposed dead
// screen bands where the cursor left the window (SDL LEAVE -> pointer
// recentre -> edge scroll broken at those edges; v0.12-RC bug 1).
// borderless-fullscreen enforcement state: remembered so PresentFrame can
// re-assert AFTER async display reconfiguration. Leaving exclusive fullscreen
// restores the desktop display mode asynchronously; if the borderless frame
// was enforced against the still-lowered mode (e.g. 1920x1080 while the 1080p
// exclusive mode is being torn down), the window would keep that stale frame
// forever — the mode restore emits NO window resize event. The periodic
// re-check (every ~60 presents; a frame fetch + compare, setFrame only when
// different) converges to a no-op once the frame matches the screen.
static bool        s_blFullscreenActive = false;
static SDL_Window* s_blFullscreenWindow = nullptr;

void EnforceBorderlessFullscreenFrame(SDL_Window* window, bool active)
{
	s_blFullscreenActive = active;
	s_blFullscreenWindow = window;

	NSWindow* nswindow = NSWindowFor(window);
	if (nswindow == nil)
		return;

	if (!active) {
		// leaving borderless-fullscreen: give the menu bar + Dock back.
		// (SDL's exclusive-fullscreen path manages its own presentation.)
		if ([NSApp presentationOptions] != NSApplicationPresentationDefault)
			[NSApp setPresentationOptions:NSApplicationPresentationDefault];
		return;
	}

	// never fight SDL while the window is (still) in an SDL fullscreen state
	// (mode transitions tear down asynchronously)
	if ((SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN_DESKTOP) != 0)
		return;

	NSScreen* screen = [nswindow screen];
	if (screen == nil)
		screen = [NSScreen mainScreen];
	if (screen == nil)
		return;

	// Auto-hide the menu bar + Dock while the game is frontmost so the whole
	// panel belongs to the window (AppKit requires AutoHideDock together with
	// AutoHideMenuBar). They reveal on deliberate edge hover, as users expect
	// from borderless mode; system UI returns automatically on app switch.
	const NSApplicationPresentationOptions wanted =
			NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock;
	if ([NSApp presentationOptions] != wanted)
		[NSApp setPresentationOptions:wanted];

	// Borderless styleMask windows are exempt from frame constraining, so an
	// explicit setFrame: to the screen frame (menu-bar band included) sticks.
	// SDL observes the change via windowDidResize/windowDidMove and updates
	// its window size/position, so SDL_GetWindowSize + the engine geometry
	// chain (SIZE_CHANGED -> UpdateGLGeometry) stay consistent.
	const NSRect target = [screen frame];
	if (!NSEqualRects([nswindow frame], target)) {
		[nswindow setFrame:target display:YES];
		LOG("[EGL] borderless-fullscreen frame enforced: %.0fx%.0f pt at (%.0f,%.0f)",
				target.size.width, target.size.height, target.origin.x, target.origin.y);
	}
}

// Recreate the pbuffer (the engine's default framebuffer) at the window's
// current pixel size so the window resizes at true resolution instead of
// scaling a fixed-size buffer. Called from ReadWindowPosAndSize on resize,
// before winSize is bound to the pbuffer size. No-op if the size is unchanged
// or the EGL context is not up yet. The CAMetalLayer drawable auto-follows
// because the present path sizes it from pbufW/pbufH each frame.
void ResizeIfNeeded(SDL_Window* window)
{
	if (eglDpy == EGL_NO_DISPLAY || eglCtx == EGL_NO_CONTEXT || eglCfg == nullptr)
		return;

	int winW = 0, winH = 0;
	SDL_GetWindowSize(window, &winW, &winH);
	if (winW <= 0 || winH <= 0)
		return;

	// A pinned benchmark render size outranks the window: resizing the pbuffer
	// to follow the window would re-introduce exactly the hardware coupling the
	// pin exists to remove, and would do it silently mid-run.
	int pinW = 0, pinH = 0;
	if (PerfPinnedRenderSize(pinW, pinH)) {
		if (pinW != pbufW || pinH != pbufH)
			LOG("[EGL] resize ignored: render size pinned to %dx%d "
			    "(SPRING_MAC_PERF_RENDER_SIZE)", pinW, pinH);
		return;
	}

	const double bsf = EffectiveBackingScale(window);
	const int    pxW = std::max(1, int(std::lround(double(winW) * bsf)));
	const int    pxH = std::max(1, int(std::lround(double(winH) * bsf)));

	if (pxW == pbufW && pxH == pbufH)
		return; // size unchanged

	EGLint pbAttribs[] = { EGL_WIDTH, pxW, EGL_HEIGHT, pxH, EGL_NONE };
	EGLSurface newSurface = eglCreatePbufferSurface(eglDpy, eglCfg, pbAttribs);
	if (newSurface == EGL_NO_SURFACE) {
		LOG_L(L_WARNING, "[EGL] resize: eglCreatePbufferSurface %dx%d failed (0x%x); keeping %dx%d",
				pxW, pxH, eglGetError(), pbufW, pbufH);
		return; // keep the old surface rather than lose the context
	}

	if (!eglMakeCurrent(eglDpy, newSurface, newSurface, eglCtx)) {
		LOG_L(L_WARNING, "[EGL] resize: eglMakeCurrent failed (0x%x); reverting", eglGetError());
		eglMakeCurrent(eglDpy, eglSfc, eglSfc, eglCtx);
		eglDestroySurface(eglDpy, newSurface);
		return;
	}

	if (eglSfc != EGL_NO_SURFACE)
		eglDestroySurface(eglDpy, eglSfc);
	eglSfc = newSurface;
	pbufW = pxW;
	pbufH = pxH;
	LOG("[EGL] resize: pbuffer -> %dx%d px (window %dx%d * %.2f)", pxW, pxH, winW, winH, bsf);
}

} // namespace MacPresent


// ---------------------------------------------------------------------------
// Readback rings + per-frame present (see MacPresent::PresentFrame below)
// ---------------------------------------------------------------------------

namespace {

// Staging-texture ring for PIPELINED readback (fallback when the GPU-pack
// ring is disabled; see PresentFrame).
//
// Why: Zink+KosmicKrisp lack the caps for Mesa's GPU PBO-pack fast path on
// TEXTURE readbacks, so a glReadPixels of the just-rendered frame falls back
// to zink_image_map -> batch_usage_wait: a synchronous CPU map that waits for
// the ENTIRE GPU pipeline to drain. Measured at ~65% of frame time in heavy
// scenes (2700-unit arena: 114ms mean swap, 5-12 fps).
//
// How: frame N blits the default framebuffer into ring[N % RB_RING]
// (GPU-queued, returns immediately) and reads back ring[(N - lag) % RB_RING],
// whose GPU work completed `lag` frames ago — the fallback map then has
// nothing to wait for. Costs `lag` frames of present latency.
constexpr int RB_RING = 3;
unsigned int rbFBO[RB_RING] = { 0, 0, 0 };
unsigned int rbTex[RB_RING] = { 0, 0, 0 };
int  rbW = 0, rbH = 0;
long rbFrame = 0;

// GPU-pack PBO ring (the current default; see PresentFrame). Reads the frame
// into a pixel-pack BUFFER via Mesa's compute-pack path (st_pbo download):
// non-blocking on the CPU AND queue-depth-independent, unlike any texture
// readback, because mapping an idle linear buffer needs no new GPU work.
// Requirements discovered with testkit/readback-bench.c:
//  - a PIXEL_PACK buffer must be bound (raw-pointer reads never GPU-pack) and
//  - the read format must match the framebuffer's component order exactly
//    (a swizzling read falls off the fast path -> sync texture map, ~30ms in
//    heavy scenes vs ~1.3ms here at 5120x2160).
constexpr int PP_RING = 4;
unsigned int ppPBO[PP_RING] = { 0, 0, 0 };
int  ppW = 0, ppH = 0;
long ppFrame = 0;

bool EnsureGpuPackRing(int w, int h)
{
	if (ppPBO[0] != 0 && ppW == w && ppH == h)
		return true;
	if (ppPBO[0] == 0)
		glGenBuffers(PP_RING, ppPBO);
	for (int i = 0; i < PP_RING; ++i) {
		glBindBuffer(GL_PIXEL_PACK_BUFFER, ppPBO[i]);
		glBufferData(GL_PIXEL_PACK_BUFFER, (GLsizeiptr)w * h * 4, nullptr, GL_STREAM_READ);
	}
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	ppW = w;
	ppH = h;
	ppFrame = 0;
	static bool logged = false;
	if (!logged) {
		LOG("[MacPresent] GPU-pack PBO-ring readback active (%dx%d)", w, h);
		logged = true;
	}
	return true;
}

bool EnsureStagingRing(int w, int h)
{
	if (rbFBO[0] != 0 && rbW == w && rbH == h)
		return true;
	if (rbFBO[0] == 0) {
		glGenFramebuffers(RB_RING, rbFBO);
		glGenTextures(RB_RING, rbTex);
	}
	GLint prevDrawFBO = 0;
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevDrawFBO);
	for (int i = 0; i < RB_RING; ++i) {
		glBindTexture(GL_TEXTURE_2D, rbTex[i]);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, nullptr);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S,     GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T,     GL_CLAMP_TO_EDGE);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, rbFBO[i]);
		glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rbTex[i], 0);
		const GLenum fst = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
		if (fst != GL_FRAMEBUFFER_COMPLETE) {
			glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prevDrawFBO);
			glBindTexture(GL_TEXTURE_2D, 0);
			LOG_L(L_WARNING, "[MacPresent] staging FBO %d incomplete: 0x%04x", i, (unsigned)fst);
			return false;
		}
	}
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prevDrawFBO);
	glBindTexture(GL_TEXTURE_2D, 0);
	rbW = w;
	rbH = h;
	rbFrame = 0;

	static bool logged = false;
	if (!logged) {
		LOG("[MacPresent] pipelined staging-ring readback active (%dx%d)", w, h);
		logged = true;
	}
	return true;
}

// Direct-present PBO ring (the zero-copy default; see PresentFrame).
// Same GPU-pack readback as the PP ring, but the slots are PERSISTENTLY
// mapped (ARB_buffer_storage) and page-aligned, so the Metal present shader
// reads the packed pixels straight from unified memory
// (MacMetalPresent_PresentPixelBuffer): the per-frame CPU map + 44MB memcpy
// into the IOSurface disappears from the main thread.
//
// Ring depth: the presented slot must not be re-packed while a present that
// reads it is still in flight. Presents pipeline at most 2 deep (budget
// semaphore in MetalPresent.mm); at lag L a slot is re-packed DP_RING - L
// frames after its present was queued, so DP_RING = 6 leaves >= 1 frame of
// margin at the maximum lag of 3. Packing into a persistently-mapped buffer
// is legal GL (unlike a plain mapped one — the bug class behind the reverted
// async-copy experiment).
constexpr int DP_RING = 6;
unsigned int dpPBO[DP_RING]   = { 0 };
void*        dpMap[DP_RING]   = { nullptr };
GLsync       dpFence[DP_RING] = { nullptr };
size_t dpAllocBytes = 0;
int    dpW = 0, dpH = 0;
long   dpFrame = 0;
bool   dpFailed = false;

void ReleaseDirectRing()
{
	if (dpPBO[0] == 0)
		return;
	// Metal must drop its wraps of the mapped pointers before we unmap.
	MacMetalPresent_InvalidatePixelBuffers();
	for (int i = 0; i < DP_RING; ++i) {
		if (dpFence[i] != nullptr) {
			glDeleteSync(dpFence[i]);
			dpFence[i] = nullptr;
		}
		if (dpMap[i] != nullptr) {
			glBindBuffer(GL_PIXEL_PACK_BUFFER, dpPBO[i]);
			glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
			dpMap[i] = nullptr;
		}
	}
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	glDeleteBuffers(DP_RING, dpPBO);
	std::fill(std::begin(dpPBO), std::end(dpPBO), 0);
	dpW = dpH = 0;
	dpFrame = 0;
}

bool EnsureDirectRing(int w, int h)
{
	if (dpPBO[0] != 0 && dpW == w && dpH == h)
		return true;
	ReleaseDirectRing();

	if (GLAD_GL_ARB_buffer_storage == 0 && !GLAD_GL_VERSION_4_4) {
		LOG_L(L_WARNING, "[MacPresent] no ARB_buffer_storage — direct present unavailable");
		return false;
	}

	const size_t pageSz     = (size_t)getpagesize();
	const size_t pixBytes   = (size_t)w * h * 4;
	const size_t allocBytes = (pixBytes + pageSz - 1) & ~(pageSz - 1); // newBufferWithBytesNoCopy needs page-multiple length

	glGetError(); // clear
	glGenBuffers(DP_RING, dpPBO);
	for (int i = 0; i < DP_RING; ++i) {
		glBindBuffer(GL_PIXEL_PACK_BUFFER, dpPBO[i]);
		glBufferStorage(GL_PIXEL_PACK_BUFFER, (GLsizeiptr)allocBytes, nullptr,
		                GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT);
		const GLenum se = glGetError();
		if (se != GL_NO_ERROR) {
			LOG_L(L_WARNING, "[MacPresent] glBufferStorage failed (slot %d, err 0x%04x)", i, se);
			glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
			ReleaseDirectRing();
			return false;
		}
		dpMap[i] = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, (GLsizeiptr)allocBytes,
		                            GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT);
		if (dpMap[i] == nullptr || ((uintptr_t)dpMap[i] & (pageSz - 1)) != 0) {
			// unaligned pointers cannot be wrapped by Metal — bail to fallback
			LOG_L(L_WARNING, "[MacPresent] persistent map %s (slot %d, ptr %p)",
			        dpMap[i] == nullptr ? "failed" : "not page-aligned", i, dpMap[i]);
			glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
			ReleaseDirectRing();
			return false;
		}
	}
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
	dpAllocBytes = allocBytes;
	dpW = w;
	dpH = h;
	dpFrame = 0;

	static bool logged = false;
	if (!logged) {
		LOG("[MacPresent] persistent PBO ring for direct present (%dx%d, %d slots x %zu bytes)",
		        w, h, DP_RING, allocBytes);
		logged = true;
	}
	return true;
}

// Pack this frame into the ring and hand the lag-frames-old slot to the Metal
// present. Returns false (and latches dpFailed) if the path is unavailable —
// the caller then runs the IOSurface fallback from this frame on.
bool DirectPresentFrame(int rdW, int rdH, GLenum readFormat, int lagFrames)
{
	if (dpFailed)
		return false;
	if (!EnsureDirectRing(rdW, rdH)) {
		dpFailed = true;
		return false;
	}

	// Sub-timers of Misc::SwapBuffers: they record only while the profiler is
	// on (/debug, or SPRING_HITCH_LOG), and let a [hitch] line say whether a
	// slow swap was the pack, the GPU-behind wait, or the Metal present.
	const int cur = (int)(dpFrame % DP_RING);
	{
		SCOPED_TIMER("Misc::SwapBuffers::MacPack");
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		glBindBuffer(GL_PIXEL_PACK_BUFFER, dpPBO[cur]);
		glReadPixels(0, 0, rdW, rdH, readFormat, GL_UNSIGNED_BYTE, nullptr);
	}
	// a silently-failing pack presents stale frames (the async-copy flicker
	// class); packing into a PERSISTENT map is legal, but verify early on
	if (dpFrame < 100) {
		const GLenum pe = glGetError();
		if (pe != GL_NO_ERROR) {
			LOG_L(L_WARNING, "[MacPresent] pack into persistent PBO failed (err 0x%04x) — disabling direct present", pe);
			glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
			dpFailed = true;
			return false;
		}
	}
	if (dpFence[cur] != nullptr)
		glDeleteSync(dpFence[cur]);
	dpFence[cur] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	glFlush(); // submit the pack now; otherwise it rides the NEXT frame's flush

	bool presented = true;
	if (dpFrame >= lagFrames) {
		// Metal must not read pages the pack compute is still writing. The
		// CPU map used to guarantee this implicitly by blocking until the
		// pack completed — and that block doubled as PIPELINE BACKPRESSURE:
		// removing it entirely (tried: present newest-completed slot, skip
		// when none) let the main thread run ahead until the GPU sat 5+
		// frames deep and most presents were SKIPPED — high "rendered" fps,
		// stale glass. Smoothness is the product, so the wait stays; the
		// copy removal is still a win everywhere the GPU keeps up.
		int old = (int)((dpFrame - lagFrames) % DP_RING);
		{
			SCOPED_TIMER("Misc::SwapBuffers::MacFenceWait");
			if (dpFence[old] != nullptr &&
			    glClientWaitSync(dpFence[old], GL_SYNC_FLUSH_COMMANDS_BIT, 0) == GL_TIMEOUT_EXPIRED) {
				static uint64_t fenceWaits = 0;
				++fenceWaits;
				// L_INFO, not L_WARNING: this fires whenever the GPU render can't keep
				// the frame budget (a normal perf symptom on a heavy scene, not an
				// error). At L_WARNING it spammed the on-screen console; keep it in the
				// log (rate-limited to powers of two) for perf diagnosis only.
				if ((fenceWaits & (fenceWaits - 1)) == 0) // log 1,2,4,8,...
					LOG_L(L_INFO, "[MacPresent] lag-%d pack fence not signaled — waiting (GPU behind, x%llu)",
					        lagFrames, (unsigned long long)fenceWaits);
				if (glClientWaitSync(dpFence[old], GL_SYNC_FLUSH_COMMANDS_BIT, 100000000ull) == GL_TIMEOUT_EXPIRED) {
					// pathological (>100ms): use the newest COMPLETED older slot
					// instead of reading a buffer mid-write; skip if none
					old = -1;
					for (int k = lagFrames + 1; k <= (int)std::min<long>(dpFrame, DP_RING - 2); ++k) {
						const int cand = (int)((dpFrame - k) % DP_RING);
						if (dpFence[cand] == nullptr ||
						    glClientWaitSync(dpFence[cand], GL_SYNC_FLUSH_COMMANDS_BIT, 0) != GL_TIMEOUT_EXPIRED) {
							old = cand;
							break;
						}
					}
				}
			}
		}
		if (old >= 0) {
			SCOPED_TIMER("Misc::SwapBuffers::MacMetalPresent");
			presented = MacMetalPresent_PresentPixelBuffer(dpMap[old], dpAllocBytes, rdW, rdH,
			                                               readFormat == GL_RGBA, true);
		}
	}
	glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

	if (!presented) {
		dpFailed = true;
		return false;
	}
	dpFrame++;
	return true;
}

} // anonymous namespace


namespace MacPresent {

bool PresentFrame()
{
	// no EGL context (pre-init or teardown): let the caller run the normal
	// SDL swap
	if (eglDpy == EGL_NO_DISPLAY || eglSfc == EGL_NO_SURFACE)
		return false;

	// self-heal the borderless-fullscreen frame after async display-mode
	// restores (see EnforceBorderlessFullscreenFrame): cheap periodic check,
	// no-op when the frame already matches the screen
	{
		static unsigned frameTick = 0;
		if (s_blFullscreenActive && s_blFullscreenWindow != nullptr && (++frameTick % 60u) == 0u)
			EnforceBorderlessFullscreenFrame(s_blFullscreenWindow, true);
	}

	// eglSwapBuffers on the (surfaceless) pbuffer presents nowhere, so
	// read the rendered default framebuffer back and blit it onto the
	// window's CAMetalLayer via Metal.
	//
	// Fast path: glReadPixels writes directly into an IOSurface-backed
	// MTLTexture (no CPU intermediate buffer, no CPU Y-flip, no
	// replaceRegion upload — Metal samples the same backing store and
	// flips during a one-triangle render pass to the drawable).
	//
	// Fallback path: SPRING_MAC_LEGACY_PRESENT=1 or AcquireIOSurfaceBuffer
	// failure routes through the original CPU staging path.
	static const bool wantLegacy = (getenv("SPRING_MAC_LEGACY_PRESENT") != nullptr);
#ifdef SPRING_MAC_DIAGNOSTICS
	// Per-frame timing instrumentation. Set SPRING_TIME_PRESENT=1
	// to log a breakdown of (lock-wait | glReadPixels | Metal present | other)
	// averaged over every 60 frames. Use to attribute the per-frame cost.
	static const bool timePresent = (getenv("SPRING_TIME_PRESENT") != nullptr);
#endif
	const int rdW = pbufW;
	const int rdH = pbufH;

	// Native read format of the default framebuffer: reading in this
	// exact component order keeps Mesa on the GPU-pack PBO path
	// (see EnsureGpuPackRing). The Metal side interprets the IOSurface
	// bytes in the same order, so colors are bit-identical either way.
	static const GLenum readFormat = []() -> GLenum {
		GLint fmt = 0, typ = 0;
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT, &fmt);
		glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE,   &typ);
		const bool byteRGBA = (fmt == GL_RGBA && typ == GL_UNSIGNED_BYTE);
		LOG("[MacPresent] impl color read fmt=0x%04x type=0x%04x -> reading %s",
		        (unsigned)fmt, (unsigned)typ, byteRGBA ? "GL_RGBA" : "GL_BGRA");
		return byteRGBA ? GL_RGBA : GL_BGRA;
	}();
	MacMetalPresent_SetSourceRGBA(readFormat == GL_RGBA);

#ifdef SPRING_MAC_DIAGNOSTICS
	const spring_time tEntry = timePresent ? spring_now() : spring_notime;
#endif

	// Direct pixel-buffer present: the Metal present shader reads the
	// persistently-mapped pack ring straight from unified memory — no
	// IOSurface staging, no per-frame CPU map + 44MB memcpy. Governed by
	// the MacPresentDirect config (mirrored by the observer registered in
	// CreateContext, so a probe widget can flip it mid-run and A/B legs
	// share one seeked process). Any setup failure falls back to the
	// IOSurface paths below.
	const bool directWanted = (presentDirect.load(std::memory_order_relaxed) != 0);

	bool directDone = false;
	if (!wantLegacy && directWanted && presentLagFrames > 0) {
		directDone = DirectPresentFrame(rdW, rdH, readFormat, presentLagFrames);
		static bool loggedFallback = false;
		if (!directDone && !loggedFallback) {
			LOG_L(L_WARNING, "[MacPresent] direct pixel-buffer path unavailable — using IOSurface fallback");
			loggedFallback = true;
		}
	}

#ifdef SPRING_MAC_DIAGNOSTICS
	if (directDone && timePresent) {
		static int    dpCnt = 0;
		static double dpMs  = 0.0;
		dpMs += (spring_now() - tEntry).toMilliSecsf();
		if (++dpCnt >= 60) {
			fprintf(stderr, "[spring-mac/present-direct] avg over %d frames: pack+present-submit %.2fms\n",
			        dpCnt, dpMs / dpCnt);
			dpCnt = 0; dpMs = 0.0;
		}
	}
#endif

	size_t ioRowBytes = 0;
	void*  ioBase     = (wantLegacy || directDone) ? nullptr
	                               : MacMetalPresent_AcquireIOSurfaceBuffer(rdW, rdH, &ioRowBytes);
#ifdef SPRING_MAC_DIAGNOSTICS
	const spring_time tAfterAcquire = timePresent ? spring_now() : spring_notime;
#endif

	if (directDone) {
		// presented above; nothing further to do this frame
	} else if (ioBase != nullptr && useGpuPackRing && presentLagFrames > 0 && EnsureGpuPackRing(rdW, rdH)) {
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);

		// queue this frame's GPU pack into the ring (CPU-non-blocking)
		const int cur = (int)(ppFrame % PP_RING);
		glBindBuffer(GL_PIXEL_PACK_BUFFER, ppPBO[cur]);
		glReadPixels(0, 0, rdW, rdH, readFormat, GL_UNSIGNED_BYTE, nullptr);
		glFlush(); // submit the pack now; otherwise it rides the NEXT frame's flush (+1 frame of map wait)
#ifdef SPRING_MAC_DIAGNOSTICS
		const spring_time tAfterRead = timePresent ? spring_now() : spring_notime;
#endif

		// map the lag-frames-old slot (idle linear buffer: instant map,
		// no GPU round-trip) and copy into the IOSurface
		if (ppFrame >= presentLagFrames) {
			const int old = (int)((ppFrame - presentLagFrames) % PP_RING);
			glBindBuffer(GL_PIXEL_PACK_BUFFER, ppPBO[old]);
			const GLsizeiptr nBytes = (GLsizeiptr)rdW * (GLsizeiptr)rdH * 4;
			if (void* mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, nBytes, GL_MAP_READ_BIT)) {
				const size_t srcRowBytes = (size_t)rdW * 4;
				if (ioRowBytes == srcRowBytes) {
					std::memcpy(ioBase, mapped, srcRowBytes * (size_t)rdH);
				} else {
					const uint8_t* srcp = static_cast<const uint8_t*>(mapped);
					uint8_t*       dstp = static_cast<uint8_t*>(ioBase);
					for (int yy = 0; yy < rdH; ++yy)
						std::memcpy(dstp + (size_t)yy * ioRowBytes,
						            srcp + (size_t)yy * srcRowBytes, srcRowBytes);
				}
				glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
			}
		}
		glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
		ppFrame++;

#ifdef SPRING_MAC_DIAGNOSTICS
		const spring_time tAfterMap = timePresent ? spring_now() : spring_notime;
#endif
		MacMetalPresent_PresentIOSurface(true);
#ifdef SPRING_MAC_DIAGNOSTICS
		if (timePresent) {
			const spring_time tAfterPresent = spring_now();
			static int    gpCnt = 0;
			static double gpAcqMs = 0.0, gpReadMs = 0.0, gpMapMs = 0.0, gpPresMs = 0.0;
			gpAcqMs  += (tAfterAcquire - tEntry).toMilliSecsf();
			gpReadMs += (tAfterRead    - tAfterAcquire).toMilliSecsf();
			gpMapMs  += (tAfterMap     - tAfterRead).toMilliSecsf();
			gpPresMs += (tAfterPresent - tAfterMap).toMilliSecsf();
			if (++gpCnt >= 60) {
				fprintf(stderr,
				    "[spring-mac/present-gpupack] avg over %d frames: acquire %.2fms | read %.2fms | map+copy %.2fms | metal-submit %.2fms\n",
				    gpCnt, gpAcqMs / gpCnt, gpReadMs / gpCnt, gpMapMs / gpCnt, gpPresMs / gpCnt);
				gpCnt = 0; gpAcqMs = gpReadMs = gpMapMs = gpPresMs = 0.0;
			}
		}
#endif
	} else if (ioBase != nullptr && presentLagFrames > 0 && EnsureStagingRing(rdW, rdH)) {
		const int cur = (int)(rbFrame % RB_RING);
		// queue this frame's blit into the ring
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, rbFBO[cur]);
		glBlitFramebuffer(0, 0, pbufW, pbufH,
		                  0, 0, rdW,   rdH,
		                  GL_COLOR_BUFFER_BIT, GL_NEAREST);
		glFlush(); // submit the batch so the blit executes during this frame

		if (rbFrame >= presentLagFrames) {
			// read back the `lag`-frames-old slot — its GPU work is done,
			// so the driver's synchronous-map fallback returns immediately
			const int old = (int)((rbFrame - presentLagFrames) % RB_RING);
			glBindFramebuffer(GL_READ_FRAMEBUFFER, rbFBO[old]);
			const int rowPixels = static_cast<int>(ioRowBytes / 4);
			if (rowPixels != rdW)
				glPixelStorei(GL_PACK_ROW_LENGTH, rowPixels);
			glReadPixels(0, 0, rdW, rdH, GL_BGRA, GL_UNSIGNED_BYTE, ioBase);
			if (rowPixels != rdW)
				glPixelStorei(GL_PACK_ROW_LENGTH, 0);
		}
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
		rbFrame++;

#ifdef SPRING_MAC_DIAGNOSTICS
		const spring_time tAfterRingRead = timePresent ? spring_now() : spring_notime;
#endif
		MacMetalPresent_PresentIOSurface(true);
#ifdef SPRING_MAC_DIAGNOSTICS
		if (timePresent) {
			const spring_time tAfterRingPresent = spring_now();
			static int    ringCnt = 0;
			static double ringAcqMs = 0.0, ringReadMs = 0.0, ringPresMs = 0.0;
			ringAcqMs  += (tAfterAcquire   - tEntry).toMilliSecsf();
			ringReadMs += (tAfterRingRead  - tAfterAcquire).toMilliSecsf();
			ringPresMs += (tAfterRingPresent - tAfterRingRead).toMilliSecsf();
			if (++ringCnt >= 60) {
				fprintf(stderr,
				    "[spring-mac/present-ring] avg over %d frames: acquire %.2fms | blit+read %.2fms | metal-submit %.2fms\n",
				    ringCnt, ringAcqMs / ringCnt, ringReadMs / ringCnt, ringPresMs / ringCnt);
				ringCnt = 0; ringAcqMs = ringReadMs = ringPresMs = 0.0;
			}
		}
#endif
	} else if (ioBase != nullptr) {
		// lag 0: synchronous readback of the current frame straight into the
		// IOSurface. Zero added present latency, but glReadPixels stalls
		// until the GPU pipeline drains — kept as the minimal-latency/
		// debugging path.
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		const int rowPixels = static_cast<int>(ioRowBytes / 4);
		if (rowPixels != rdW)
			glPixelStorei(GL_PACK_ROW_LENGTH, rowPixels);
		glReadPixels(0, 0, rdW, rdH, GL_BGRA, GL_UNSIGNED_BYTE, ioBase);
		if (rowPixels != rdW)
			glPixelStorei(GL_PACK_ROW_LENGTH, 0);

#ifdef SPRING_MAC_DIAGNOSTICS
		// Debug: dump rendered frames to raw files for inspection.
		// SPRING_MAC_DUMP_FRAME=<prefix>; writes <prefix>.NNN.raw
		// (8-byte header: uint32 w,h; then row-major BGRA, bottom-up).
		if (const char* dp = getenv("SPRING_MAC_DUMP_FRAME")) {
			static int df = 0;
			if (df < 80 && (df % 6) == 0) {
				char path[1024];
				snprintf(path, sizeof(path), "%s.%03d.raw", dp, df);
				if (FILE* f = fopen(path, "wb")) {
					const uint32_t hdr[2] = { (uint32_t)rdW, (uint32_t)rdH };
					fwrite(hdr, sizeof(hdr), 1, f);
					const uint8_t* row = static_cast<const uint8_t*>(ioBase);
					for (int y = 0; y < rdH; ++y) {
						fwrite(row + (size_t)y * ioRowBytes, 1, (size_t)rdW * 4, f);
					}
					fclose(f);
				}
			}
			df++;
		}
#endif

		MacMetalPresent_PresentIOSurface(true);
	} else {
		static bool loggedLegacy = false;
		if (!loggedLegacy) {
			LOG_L(L_WARNING, "[MacPresent] LEGACY CPU-staging path active (%s)",
			        wantLegacy ? "forced via SPRING_MAC_LEGACY_PRESENT" : "IOSurface acquire failed");
			loggedLegacy = true;
		}
		// Legacy CPU-staging fallback.
		const size_t need = static_cast<size_t>(pbufW) * pbufH * 4;
		if (presentBuf.size() < need)
			presentBuf.resize(need);
		glReadPixels(0, 0, pbufW, pbufH, GL_BGRA, GL_UNSIGNED_BYTE, presentBuf.data());
#ifdef SPRING_MAC_DIAGNOSTICS
		if (const char* dp = getenv("SPRING_MAC_DUMP_FRAME")) {
			static int df = 0;
			if (df < 80 && (df % 6) == 0) {
				char path[1024];
				snprintf(path, sizeof(path), "%s.%03d.raw", dp, df);
				if (FILE* f = fopen(path, "wb")) {
					const uint32_t hdr[2] = { (uint32_t)pbufW, (uint32_t)pbufH };
					fwrite(hdr, sizeof(hdr), 1, f);
					fwrite(presentBuf.data(), 1, need, f);
					fclose(f);
				}
			}
			df++;
		}
#endif
		MacMetalPresent_PresentBGRA(pbufW, pbufH, presentBuf.data(), true);
	}
	// We replaced SDL_GL_SwapWindow (which serviced the Cocoa run loop),
	// so pump events here to let CoreAnimation actually composite the
	// presented drawable — including during the single-threaded load.
	SDL_PumpEvents();
	return true;
}

#ifdef SPRING_MAC_DIAGNOSTICS
// Headless verification capture. Draw() has already rendered into the
// default FBO by the time SwapBuffers() runs, so we can read it back here
// even when the actual present/swap is suppressed (allowSwapBuffers==false,
// e.g. an unfocused/background launch).
// Writes <prefix>.NNNN.raw (uint32 w,h header + w*h*4 BGRA, bottom-up).
void DiagCaptureFrame()
{
	const char* cp = getenv("SPRING_FRAME_CAPTURE");
	if (cp == nullptr)
		return;
	if (eglDpy == EGL_NO_DISPLAY || eglSfc == EGL_NO_SURFACE || pbufW <= 0 || pbufH <= 0)
		return;

	static int cap = 0;
	static const int capEvery = [](){ const char* e = getenv("SPRING_FRAME_CAPTURE_EVERY"); return e ? std::max(1, atoi(e)) : 30; }();
	static const int capLimit = [](){ const char* e = getenv("SPRING_FRAME_CAPTURE_LIMIT"); return e ? atoi(e) * capEvery : 1800; }();
	if ((cap % capEvery) == 0 && cap < capLimit) {
		const size_t need = static_cast<size_t>(pbufW) * pbufH * 4;
		if (presentBuf.size() < need)
			presentBuf.resize(need);
		glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
		glReadPixels(0, 0, pbufW, pbufH, GL_BGRA, GL_UNSIGNED_BYTE, presentBuf.data());
		char path[1024];
		snprintf(path, sizeof(path), "%s.%04d.raw", cp, cap);
		if (FILE* f = fopen(path, "wb")) {
			const uint32_t hdr[2] = { (uint32_t)pbufW, (uint32_t)pbufH };
			fwrite(hdr, sizeof(hdr), 1, f);
			fwrite(presentBuf.data(), 1, need, f);
			fclose(f);
		}
	}
	cap++;
}

// Tracer bullet: when SPRING_MAC_PRESENT_TEST is set, flash the window
// red/blue for ~8s by rendering a clear and presenting it to the window's
// CAMetalLayer via the manual Metal present path (glReadPixels -> MTLTexture
// -> blit to drawable). If the window flashes, the manual present works.
void DiagRunPresentTest()
{
	const char* e = getenv("SPRING_MAC_PRESENT_TEST");
	if (e == nullptr || e[0] != '1')
		return;

	const bool metalOk = MacMetalPresent_Init(metalLayer);
	GLint vp[4] = {0, 0, 1280, 720};
	glGetIntegerv(GL_VIEWPORT, vp);
	const int rw = (vp[2] > 0) ? vp[2] : 1280;
	const int rh = (vp[3] > 0) ? vp[3] : 720;
	std::vector<unsigned char> buf(static_cast<size_t>(rw) * rh * 4);
	fprintf(stderr, "[PRESENT_TEST] metalInit=%d flashing ~8s via Metal (%dx%d)\n", (int)metalOk, rw, rh);
	for (int i = 0; i < 16; i++) {
		const bool odd = (i % 2) != 0;
		glClearColor(odd ? 1.0f : 0.0f, 0.15f, odd ? 0.0f : 1.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glReadPixels(0, 0, rw, rh, GL_BGRA, GL_UNSIGNED_BYTE, buf.data());
		MacMetalPresent_PresentBGRA(rw, rh, buf.data(), false); // solid color: no flip needed
		fprintf(stderr, "[PRESENT_TEST] frame %d color=%s\n", i, odd ? "RED" : "BLUE");
		// Pump the Cocoa run loop so CoreAnimation actually composites each
		// presented frame (otherwise only the final frame shows on screen).
		SDL_PumpEvents();
		SDL_Event ev; while (SDL_PollEvent(&ev)) {}
		SDL_Delay(500);
	}
	fprintf(stderr, "[PRESENT_TEST] done\n");
}
#endif // SPRING_MAC_DIAGNOSTICS

} // namespace MacPresent

#endif // __APPLE__ && !HEADLESS
