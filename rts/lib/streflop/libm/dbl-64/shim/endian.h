/* minimal endian.h shim: x86_64 and arm64 are both little-endian */
#ifndef STREFLOP_DBL64_ENDIAN_H
#define STREFLOP_DBL64_ENDIAN_H
#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN    4321
#define __BYTE_ORDER __LITTLE_ENDIAN
#define LITTLE_ENDIAN __LITTLE_ENDIAN
#define BIG_ENDIAN    __BIG_ENDIAN
#define BYTE_ORDER    __BYTE_ORDER
#endif

/* IBM sources use these */
#define LITTLE_ENDI 1
#undef BIG_ENDI

/* little-endian double layout: i[1] = sign/exponent word */
#ifndef HIGH_HALF
#define HIGH_HALF 1
#define LOW_HALF 0
#endif
