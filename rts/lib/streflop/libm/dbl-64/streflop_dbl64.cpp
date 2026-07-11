/* fleet parity: the x86 fleet's glibc is baseline (no FMA, no toint
   intrinsics); force the same code paths + table layouts on arm64 */
#undef __FP_FAST_FMA
#undef __FP_FAST_FMAF
#define TOINT_INTRINSICS 0
/* streflop dbl-64: glibc 2.39 double-precision implementations compiled in,
   so Double math is bit-exact with the x86 fleet (which resolves these from
   glibc) instead of the host libm. Imported per-function; each function's
   bit-exactness is verified by scripts/double-fn-probe.cpp against the
   x86_64+glibc build.

   MUST be compiled with -ffp-contract=off and WITHOUT FMA paths (no DLA_FMS):
   the fleet's glibc is baseline-x86_64 C (dla.h emulation path). */

// glibc internals expect these includes to resolve; shim/ provides minimal ones
#include <cmath>
#include <cfloat>
#include <fenv.h>
#include <stdint.h>

// prevent dla.h from using real fused ops
#undef DLA_FMS

// glibc sources reference these; keep them inert
#define __glibc_likely(x) (x)
#define __glibc_unlikely(x) (x)
#define attribute_hidden
#define SHLIB_COMPAT(a,b,c) 0

namespace streflop_libm {

// entry points use glibc-internal names; Math dispatch calls __ieee754_atan2
#define __ieee754_atan2 streflop_dbl64_atan2_impl
extern "C++" {
#include "e_atan2.c"
}
#undef __ieee754_atan2

double __ieee754_atan2(double y, double x) { return streflop_dbl64_atan2_impl(y, x); }

}
