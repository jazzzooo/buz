#include "BunPerf.h"

#if defined(__APPLE__)
#include <os/signpost.h>
#include <cstdlib>
#include "generated_perf_trace_events.h"

extern "C" BunPerfLog* bun_perf_log() noexcept
{
    static os_log_t log = os_log_create("com.bun.bun", "PointsOfInterest");
    return log;
}

extern "C" uint64_t bun_perf_signpost_id(BunPerfLog* log) noexcept
{
    return os_signpost_id_generate(log);
}

extern "C" void bun_perf_signpost_emit(BunPerfLog* log, uint64_t id, uint8_t phase, int32_t event) noexcept
{
    os_signpost_type_t type;
    switch (phase) {
    case BUN_PERF_EVENT: type = OS_SIGNPOST_EVENT; break;
    case BUN_PERF_INTERVAL_BEGIN: type = OS_SIGNPOST_INTERVAL_BEGIN; break;
    case BUN_PERF_INTERVAL_END: type = OS_SIGNPOST_INTERVAL_END; break;
    default: std::abort();
    }
    // The SDK requires a literal event name at each emission site.
    switch (event) {
#define EMIT(name, value) \
    case value: \
        os_signpost_emit_with_type(log, type, id, #name, ""); \
        return;
        FOR_EACH_TRACE_EVENT(EMIT)
#undef EMIT
    default: std::abort();
    }
}
#endif
