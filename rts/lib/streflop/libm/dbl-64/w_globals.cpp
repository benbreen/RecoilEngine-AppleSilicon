/* Fleet-parity overrides for the C double math symbols the engine (and its
   Lua/synced code) calls directly. On Linux these resolve to glibc; on macOS
   they resolved to libSystem (different bits -> cross-platform desync).
   Defining them here makes every in-binary caller use the imported glibc
   implementations. Exact IEEE ops (sqrt, fmod, remainder, floor...) are NOT
   overridden — hardware-identical everywhere. */
#include <cmath>

namespace streflop_libm {
double __sin(double); double __cos(double); double __tan(double);
double __atan(double); double __ieee754_atan2(double, double);
double __ieee754_asin(double); double __ieee754_acos(double);
double __ieee754_exp(double); double __ieee754_log(double);
double __ieee754_log2(double); double __ieee754_log10(double);
double __ieee754_pow(double, double); double __ieee754_sinh(double);
double __ieee754_cosh(double); double __tanh(double);
double __expm1(double); double __log1p(double); double __ieee754_hypot(double, double);
}

extern "C" {
double sin(double x)            { return streflop_libm::__sin(x); }
double cos(double x)            { return streflop_libm::__cos(x); }
double tan(double x)            { return streflop_libm::__tan(x); }
double atan(double x)           { return streflop_libm::__atan(x); }
double atan2(double y, double x){ return streflop_libm::__ieee754_atan2(y, x); }
double asin(double x)           { return streflop_libm::__ieee754_asin(x); }
double acos(double x)           { return streflop_libm::__ieee754_acos(x); }
double exp(double x)            { return streflop_libm::__ieee754_exp(x); }
double log(double x)            { return streflop_libm::__ieee754_log(x); }
double log2(double x)           { return streflop_libm::__ieee754_log2(x); }
double log10(double x)          { return streflop_libm::__ieee754_log10(x); }
double pow(double x, double y)  { return streflop_libm::__ieee754_pow(x, y); }
double sinh(double x)           { return streflop_libm::__ieee754_sinh(x); }
double cosh(double x)           { return streflop_libm::__ieee754_cosh(x); }
double tanh(double x)           { return streflop_libm::__tanh(x); }
double expm1(double x)          { return streflop_libm::__expm1(x); }
double log1p(double x)          { return streflop_libm::__log1p(x); }
double hypot(double x, double y){ return streflop_libm::__ieee754_hypot(x, y); }
}

/* --- Apple clang emits __sincos_stret for paired sin/cos calls, bypassing the
   sin/cos overrides above; forward it too. Same for the float variant. --- */
namespace streflop_libm {
float __sinf(float); float __cosf(float); float __tanf(float); float __atanf(float);
float __ieee754_atan2f(float, float); float __ieee754_asinf(float); float __ieee754_acosf(float);
float __ieee754_expf(float); float __ieee754_logf(float); float __ieee754_powf(float, float);
float __ieee754_log2f(float); float __ieee754_log10f(float);
float __ieee754_sinhf(float); float __ieee754_coshf(float); float __tanhf(float);
}
extern "C" {
/* match the SDK's exact prototypes (math.h declares __double2/__float2) */
struct __double2 __sincos_stret(double x) {
	struct __double2 r; r.__sinval = streflop_libm::__sin(x); r.__cosval = streflop_libm::__cos(x); return r;
}
struct __float2 __sincosf_stret(float x) {
	struct __float2 r; r.__sinval = streflop_libm::__sinf(x); r.__cosval = streflop_libm::__cosf(x); return r;
}

/* --- float libm: some in-binary code calls these without streflop; forward to
   streflop's flt-32 (proven fleet-identical) --- */
float sinf(float x)             { return streflop_libm::__sinf(x); }
float cosf(float x)             { return streflop_libm::__cosf(x); }
float tanf(float x)             { return streflop_libm::__tanf(x); }
float atanf(float x)            { return streflop_libm::__atanf(x); }
float atan2f(float y, float x)  { return streflop_libm::__ieee754_atan2f(y, x); }
float asinf(float x)            { return streflop_libm::__ieee754_asinf(x); }
float acosf(float x)            { return streflop_libm::__ieee754_acosf(x); }
float expf(float x)             { return streflop_libm::__ieee754_expf(x); }
float logf(float x)             { return streflop_libm::__ieee754_logf(x); }
float log2f(float x)            { return streflop_libm::__ieee754_log2f(x); }
float log10f(float x)           { return streflop_libm::__ieee754_log10f(x); }
float powf(float x, float y)    { return streflop_libm::__ieee754_powf(x, y); }
float sinhf(float x)            { return streflop_libm::__ieee754_sinhf(x); }
float coshf(float x)            { return streflop_libm::__ieee754_coshf(x); }
float tanhf(float x)            { return streflop_libm::__tanhf(x); }
}
