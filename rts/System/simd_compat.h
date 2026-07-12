/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#ifndef _SIMD_COMPAT_H
#define _SIMD_COMPAT_H

#ifdef SSE2NEON
    #include "lib/sse2neon/sse2neon.h"
#else
    #include <x86intrin.h>
    #include <immintrin.h>
    #include <xmmintrin.h>
    #include <emmintrin.h>
#endif

#endif // _SIMD_COMPAT_H
