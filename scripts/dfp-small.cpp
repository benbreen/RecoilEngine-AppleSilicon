// Per-function bit-exactness probe for streflop Double transcendentals.
// Names WHICH double function diverges between builds (root-cause narrowing).
#include <cstdio>
#include <cstdint>
#include <cstring>
#include "streflop_cond.h"

static uint64_t h;
static void reset() { h = 1469598103934665603ULL; }
static void tapd(double v) { uint64_t b; memcpy(&b, &v, 8); h ^= b; h *= 1099511628211ULL; }

int main() {
    using streflop::Double;

    reset();
    for (int i = -80; i <= 80; i++)
        for (int j = -80; j <= 80; j++) {
            if (i == 0 && j == 0) continue;
            tapd(streflop::atan2(Double(i * 0.0037), Double(j * 0.0041)));
        }
    printf("atan2  %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::sin(Double(x))); }
    printf("sin    %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::cos(Double(x))); }
    printf("cos    %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::tan(Double(x))); }
    printf("tan    %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::floor(Double(x*1.7))); }
    printf("floor  %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 40000; i++) { double x = -10.0 + 20.0*(double)i/40000.0; tapd(streflop::fmod(Double(x), Double(0.7853981633974483))); }
    printf("fmod   %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 1; i <= 40000; i++) { double x = 20.0*(double)i/40000.0; tapd(streflop::sqrt(Double(x))); tapd(streflop::log(Double(x))); }
    printf("sqrtlog %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 20000; i++) { double x = -1.0 + 2.0*(double)i/20000.0; tapd(streflop::asin(Double(x))); tapd(streflop::acos(Double(x))); }
    printf("asinacos %016llx\n", (unsigned long long)h);

    reset();
    for (int i = 0; i <= 20000; i++) { double x = -20.0 + 40.0*(double)i/20000.0; tapd(streflop::exp(Double(x))); tapd(streflop::atan(Double(x))); }
    printf("expatan %016llx\n", (unsigned long long)h);
    return 0;
}
