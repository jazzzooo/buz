#include "config.h"
#include "JSPerformanceResourceTiming.h"

#include "SchemaBindings.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

WTF::String bunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_initiatorType(
    CppEngineCallContext<JSPerformanceResourceTiming>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_initiatorType_Arguments&)
{
    return ctx.wrapped().initiatorType();
}

WTF::String bunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_nextHopProtocol(
    CppEngineCallContext<JSPerformanceResourceTiming>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_nextHopProtocol_Arguments&)
{
    return ctx.wrapped().nextHopProtocol();
}

#define BUN_RESOURCE_TIMING_DOUBLE_GETTER(name) \
    double bunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_##name( \
        CppEngineCallContext<JSPerformanceResourceTiming>& ctx, \
        const BunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_##name##_Arguments&) \
    { \
        return ctx.wrapped().name(); \
    }

BUN_RESOURCE_TIMING_DOUBLE_GETTER(workerStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(redirectStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(redirectEnd)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(fetchStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(domainLookupStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(domainLookupEnd)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(connectStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(connectEnd)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(secureConnectionStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(requestStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(responseStart)
BUN_RESOURCE_TIMING_DOUBLE_GETTER(responseEnd)

#undef BUN_RESOURCE_TIMING_DOUBLE_GETTER

#define BUN_RESOURCE_TIMING_SIZE_GETTER(name) \
    uint64_t bunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_##name( \
        CppEngineCallContext<JSPerformanceResourceTiming>& ctx, \
        const BunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_##name##_Arguments&) \
    { \
        return ctx.wrapped().name(); \
    }

BUN_RESOURCE_TIMING_SIZE_GETTER(transferSize)
BUN_RESOURCE_TIMING_SIZE_GETTER(encodedBodySize)
BUN_RESOURCE_TIMING_SIZE_GETTER(decodedBodySize)

#undef BUN_RESOURCE_TIMING_SIZE_GETTER

static WTF::Vector<PerformanceServerTimingSnapshotResult> serverTimingResult(
    CppEngineCallContext<JSPerformanceResourceTiming>& ctx)
{
    auto& global = ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    const auto timings = ctx.wrapped().serverTiming();
    WTF::Vector<PerformanceServerTimingSnapshotResult> result;
    if (!result.tryReserveInitialCapacity(timings.size())) {
        throwOutOfMemoryError(&global, scope);
        return {};
    }
    for (const auto& timing : timings) {
        result.unsafeAppendWithoutCapacityCheck(PerformanceServerTimingSnapshotResult {
            .name = timing.name,
            .duration = timing.duration,
            .description = timing.description,
        });
    }
    return result;
}

WTF::Vector<PerformanceServerTimingSnapshotResult> bunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_serverTiming(
    CppEngineCallContext<JSPerformanceResourceTiming>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_getter_serverTiming_Arguments&)
{
    return serverTimingResult(ctx);
}

PerformanceResourceTimingJSONDictionaryResult bunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_method_toJSON(
    CppEngineCallContext<JSPerformanceResourceTiming>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceResourceTiming_method_toJSON_Arguments&)
{
    auto& timing = ctx.wrapped();
    return {
        .name = timing.name(),
        .entryType = String { timing.entryType() },
        .startTime = timing.startTime(),
        .duration = timing.duration(),
        .initiatorType = timing.initiatorType(),
        .nextHopProtocol = timing.nextHopProtocol(),
        .workerStart = timing.workerStart(),
        .redirectStart = timing.redirectStart(),
        .redirectEnd = timing.redirectEnd(),
        .fetchStart = timing.fetchStart(),
        .domainLookupStart = timing.domainLookupStart(),
        .domainLookupEnd = timing.domainLookupEnd(),
        .connectStart = timing.connectStart(),
        .connectEnd = timing.connectEnd(),
        .secureConnectionStart = timing.secureConnectionStart(),
        .requestStart = timing.requestStart(),
        .responseStart = timing.responseStart(),
        .responseEnd = timing.responseEnd(),
        .transferSize = timing.transferSize(),
        .encodedBodySize = timing.encodedBodySize(),
        .decodedBodySize = timing.decodedBodySize(),
        .serverTiming = serverTimingResult(ctx),
    };
}

} // namespace Bun::Bindgen::Cpp
