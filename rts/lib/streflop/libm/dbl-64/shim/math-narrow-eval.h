#ifndef MNE_H
#define MNE_H
/* x87-only excess-precision barrier; identity on SSE/NEON */
#define math_narrow_eval(x) (x)
#endif
