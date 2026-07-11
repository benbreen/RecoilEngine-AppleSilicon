/* fleet parity: the x86 fleet's glibc is baseline (no FMA, no toint
   intrinsics); force the same code paths + table layouts on arm64 */
#undef __FP_FAST_FMA
#undef __FP_FAST_FMAF
#define TOINT_INTRINSICS 0
/* auto-generated wrapper: glibc 2.39 dbl-64 -> streflop_libm (bit-exact doubles) */
#include <cmath>
#include <cfloat>
#include <fenv.h>
#include <stdint.h>
#undef DLA_FMS
#define __glibc_likely(x) (x)
#define __glibc_unlikely(x) (x)
#define attribute_hidden
#define SHLIB_COMPAT(a,b,c) 0
#define libm_alias_double(from, to)
#define libm_alias_double_other(from, to)
#define strong_alias(a,b)
#define weak_alias(a,b)
namespace streflop_libm {
/* cross-unit forward declarations */
double __ieee754_log(double); double __ieee754_exp(double);
double __sin(double); double __cos(double);
int __branred(double, double*, double*);
double __expm1(double); double __log1p(double);
#ifndef hidden_def
#define hidden_def(x)
#endif
#ifndef NOINLINE
#define NOINLINE __attribute__((noinline))
#endif
#include <cerrno>
#ifndef __set_errno
#define __set_errno(e) (errno = (e))
#endif
#ifndef __always_inline
#define __always_inline inline __attribute__((always_inline))
#endif
}
namespace streflop_libm {
extern "C++" {
#include "e_exp_data.c"
}
}
