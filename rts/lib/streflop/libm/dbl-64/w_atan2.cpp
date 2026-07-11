/* fleet parity: the x86 fleet's glibc is baseline (no FMA, no toint
   intrinsics); force the same code paths + table layouts on arm64 */
#undef __FP_FAST_FMA
#undef __FP_FAST_FMAF
#define TOINT_INTRINSICS 0
