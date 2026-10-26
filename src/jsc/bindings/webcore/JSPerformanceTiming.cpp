#include "config.h"
#include "SchemaBindings.h"

namespace Bun::Bindgen::Cpp {

#define BUN_PERFORMANCE_TIMING_GETTER(name) \
    uint64_t bunBindgenCpp_PerformanceTiming_PerformanceTiming_getter_##name( \
        CppCallContext&, \
        const BunBindgenCpp_PerformanceTiming_PerformanceTiming_getter_##name##_Arguments&) \
    { \
        return 0; \
    }

BUN_PERFORMANCE_TIMING_GETTER(navigationStart)
BUN_PERFORMANCE_TIMING_GETTER(unloadEventStart)
BUN_PERFORMANCE_TIMING_GETTER(unloadEventEnd)
BUN_PERFORMANCE_TIMING_GETTER(redirectStart)
BUN_PERFORMANCE_TIMING_GETTER(redirectEnd)
BUN_PERFORMANCE_TIMING_GETTER(fetchStart)
BUN_PERFORMANCE_TIMING_GETTER(domainLookupStart)
BUN_PERFORMANCE_TIMING_GETTER(domainLookupEnd)
BUN_PERFORMANCE_TIMING_GETTER(connectStart)
BUN_PERFORMANCE_TIMING_GETTER(connectEnd)
BUN_PERFORMANCE_TIMING_GETTER(secureConnectionStart)
BUN_PERFORMANCE_TIMING_GETTER(requestStart)
BUN_PERFORMANCE_TIMING_GETTER(responseStart)
BUN_PERFORMANCE_TIMING_GETTER(responseEnd)
BUN_PERFORMANCE_TIMING_GETTER(domLoading)
BUN_PERFORMANCE_TIMING_GETTER(domInteractive)
BUN_PERFORMANCE_TIMING_GETTER(domContentLoadedEventStart)
BUN_PERFORMANCE_TIMING_GETTER(domContentLoadedEventEnd)
BUN_PERFORMANCE_TIMING_GETTER(domComplete)
BUN_PERFORMANCE_TIMING_GETTER(loadEventStart)
BUN_PERFORMANCE_TIMING_GETTER(loadEventEnd)

#undef BUN_PERFORMANCE_TIMING_GETTER

PerformanceTimingJSONDictionaryResult bunBindgenCpp_PerformanceTiming_PerformanceTiming_method_toJSON(
    CppCallContext&,
    const BunBindgenCpp_PerformanceTiming_PerformanceTiming_method_toJSON_Arguments&)
{
    return {};
}

PerformanceTimingSnapshotResult bunBindgenCpp_WebCorePerformance_createPerformanceTiming(
    CppCallContext&,
    const BunBindgenCpp_WebCorePerformance_createPerformanceTiming_Arguments&)
{
    return { .brand = true };
}

} // namespace Bun::Bindgen::Cpp
