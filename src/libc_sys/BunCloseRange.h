#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { BUN_CLOSE_RANGE_CLOEXEC = 1U << 2 };

/* Uses no allocator or userspace locks, including on the fallback path. */
int bun_close_range(uint32_t first, uint32_t last, uint32_t flags);

#ifdef __cplusplus
}
#endif
