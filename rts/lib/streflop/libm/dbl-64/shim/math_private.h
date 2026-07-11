/* Minimal glibc math_private.h shim for streflop dbl-64 import.
   Provides only what the imported IBM/ARM sources need; FPU state is
   managed by streflop (round-to-nearest, DN on), so the SET_RESTORE_ROUND
   machinery collapses to no-ops. */
#ifndef STREFLOP_DBL64_MATH_PRIVATE_H
#define STREFLOP_DBL64_MATH_PRIVATE_H

#include <stdint.h>
#include <string.h>

typedef union { double value; struct { uint32_t lsw; uint32_t msw; } parts; uint64_t word; } ieee_double_shape_type_le;
/* little-endian on both x86_64 and arm64 */
#define EXTRACT_WORDS(ix0,ix1,d)  do { uint64_t __w; memcpy(&__w,&(d),8); (ix0)=(uint32_t)(__w>>32); (ix1)=(uint32_t)__w; } while(0)
#define INSERT_WORDS(d,ix0,ix1)   do { uint64_t __w=(((uint64_t)(uint32_t)(ix0))<<32)|(uint32_t)(ix1); memcpy(&(d),&__w,8); } while(0)
#define GET_HIGH_WORD(i,d)        do { uint64_t __w; memcpy(&__w,&(d),8); (i)=(uint32_t)(__w>>32); } while(0)
#define GET_LOW_WORD(i,d)         do { uint64_t __w; memcpy(&__w,&(d),8); (i)=(uint32_t)__w; } while(0)
#define SET_HIGH_WORD(d,v)        do { uint64_t __w; memcpy(&__w,&(d),8); __w=(__w&0xffffffffULL)|(((uint64_t)(uint32_t)(v))<<32); memcpy(&(d),&__w,8); } while(0)
#define SET_LOW_WORD(d,v)         do { uint64_t __w; memcpy(&__w,&(d),8); __w=(__w&0xffffffff00000000ULL)|(uint32_t)(v); memcpy(&(d),&__w,8); } while(0)
#define EXTRACT_WORDS64(i,d)      do { memcpy(&(i),&(d),8); } while(0)
#define INSERT_WORDS64(d,i)       do { memcpy(&(d),&(i),8); } while(0)

#endif
