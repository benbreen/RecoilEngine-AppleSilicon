/* streflop guarantees round-to-nearest + fixed FPU state for synced code, so
   glibc's rounding-mode save/restore is a no-op here. */
#ifndef STREFLOP_DBL64_FENV_PRIVATE_H
#define STREFLOP_DBL64_FENV_PRIVATE_H
#define SET_RESTORE_ROUND(m)          do { } while (0)
#define SET_RESTORE_ROUND_NOEX(m)     do { } while (0)
#define SET_RESTORE_ROUND_53BIT(m)    do { } while (0)
#define libc_feholdexcept_setround(e,m) do { } while (0)
#define libc_fesetenv(e)              do { } while (0)
#endif
