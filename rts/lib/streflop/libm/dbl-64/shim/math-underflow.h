#ifndef MUND_H
#define MUND_H
/* only raises FP exceptions; value-neutral -> no-op */
#define math_check_force_underflow(x) do{}while(0)
#define math_check_force_underflow_nonneg(x) do{}while(0)
#define math_check_force_underflow_complex(x) do{}while(0)
#endif
