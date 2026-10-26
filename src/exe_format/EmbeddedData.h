#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t BunEmbeddedStatus;
enum {
    BUN_EMBEDDED_ABSENT = 0,
    BUN_EMBEDDED_READY = 1,
    BUN_EMBEDDED_INVALID = 2,
};

/* The OS owns the returned image pages until process exit. Other statuses
   return a null pointer and zero length. */
BunEmbeddedStatus bun_embedded_data(const uint8_t** out_data, size_t* out_length);

#ifdef __cplusplus
}
#endif
