/* glibc alias-macro replacements: forward the names streflop's Math dispatch
   expects (__ieee754_* and plain tan/atan) to the imported glibc units' actual
   entry points. glibc did this with strong_alias/libm_alias macros, which the
   wrapper shims neutralize. */
namespace streflop_libm {

double __exp(double);  double __log(double);   double __log2(double);
double __exp2(double); double __pow(double, double); double __hypot(double, double);
double __tan(double);  double __atan(double);

double __ieee754_exp(double x)             { return __exp(x); }
double __ieee754_log(double x)             { return __log(x); }
double __ieee754_log2(double x)            { return __log2(x); }
double __ieee754_exp2(double x)            { return __exp2(x); }
double __ieee754_pow(double x, double y)   { return __pow(x, y); }
double __ieee754_hypot(double x, double y) { return __hypot(x, y); }
double tan(double x)                       { return __tan(x); }
double atan(double x)                      { return __atan(x); }

}
