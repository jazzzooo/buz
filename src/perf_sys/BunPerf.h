#pragma once

#include <stdint.h>

#ifdef __cplusplus
#define BUN_PERF_NOEXCEPT noexcept
extern "C" {
#else
#define BUN_PERF_NOEXCEPT
#endif

typedef struct os_log_s BunPerfLog;
enum {
    BUN_PERF_EVENT = 0,
    BUN_PERF_INTERVAL_BEGIN = 1,
    BUN_PERF_INTERVAL_END = 2,
};

/* The process owns the shared log until exit. */
BunPerfLog* bun_perf_log(void) BUN_PERF_NOEXCEPT;
uint64_t bun_perf_signpost_id(BunPerfLog* log) BUN_PERF_NOEXCEPT;
void bun_perf_signpost_emit(BunPerfLog* log, uint64_t id, uint8_t phase, int32_t event) BUN_PERF_NOEXCEPT;

#ifdef __cplusplus
}
#endif
#undef BUN_PERF_NOEXCEPT
