#include "config.h"
#include "JSPerformance.h"

#include "DOMWrapperWorld.h"
#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSEventListener.h"
#include "JSPerformanceEntry.h"
#include "JSPerformanceMark.h"
#include "JSPerformanceMeasure.h"
#include "PerformanceMarkOptions.h"
#include "PerformanceMeasureOptions.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <limits>

namespace WebCore {

using namespace JSC;

bool JSPerformanceOwner::isReachableFromOpaqueRoots(
    JSC::Handle<JSC::Unknown> handle,
    void*,
    AbstractSlotVisitor& visitor,
    ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSPerformance>(handle.slot()->asCell());
    if (visitor.containsOpaqueRoot(static_cast<EventTarget*>(&wrapper->wrapped()))) {
        if (reason) [[unlikely]]
            *reason = "Reachable from Event"_s;
        return true;
    }
    if (!wrapper->wrapped().scriptExecutionContext())
        return false;
    if (reason) [[unlikely]]
        *reason = "Reachable from ScriptExecutionContext"_s;
    return visitor.containsOpaqueRoot(&wrapper->wrapped());
}

void JSPerformanceOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSPerformance*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

static CppResultSequence<JSValue> performanceEntriesResult(
    CppEngineCallContext<JSPerformance>& context,
    NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>>&& entriesResult)
{
    auto& global = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (!entriesResult) {
        throwOutOfMemoryError(&global, scope);
        return {};
    }
    const auto& entries = *entriesResult;
    CppResultSequence<JSValue> result;
    if (!result.reserveCapacity(context.results(), entries.size()))
        return {};
    auto* domGlobal = defaultGlobalObject(&global);
    for (const auto& entry : entries) {
        RELEASE_ASSERT(entry);
        auto value = toJS(&global, domGlobal, *entry);
        RETURN_IF_EXCEPTION(scope, {});
        if (!result.append(context.results(), value))
            return {};
    }
    return result;
}

template<typename Entry>
static JSValue performanceEntryToJS(
    CppEngineCallContext<JSPerformance>& context,
    JSC::ThrowScope& scope,
    ExceptionOr<Ref<Entry>>&& entry)
{
    RETURN_IF_EXCEPTION(scope, {});
    if (entry.hasException()) [[unlikely]] {
        propagateException(context.globalObject, scope, entry.releaseException());
        return {};
    }
    auto value = toJSNewlyCreated(
        &context.globalObject,
        defaultGlobalObject(&context.globalObject),
        entry.releaseReturnValue());
    RETURN_IF_EXCEPTION(scope, {});
    return value;
}

double bunBindgenCpp_WebCorePerformance_Performance_method_now(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_now_Arguments&)
{
    return context.wrapped().now();
}

double bunBindgenCpp_WebCorePerformance_Performance_getter_timeOrigin(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_getter_timeOrigin_Arguments&)
{
    return context.wrapped().timeOrigin();
}

static JSValue performanceTiming(CppEngineCallContext<JSPerformance>& context)
{
    if (auto cached = context.wrapper.raw_slot_timing(); !cached.isEmpty())
        return cached;
    auto* global = &context.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto factory = bun_bindgen_source_function_WebCorePerformance_createPerformanceTiming_value(defaultGlobalObject(global));
    RETURN_IF_EXCEPTION(scope, {});
    auto result = profiledCall(global, ProfilingReason::API, factory, getCallData(factory), jsUndefined(), ArgList());
    RETURN_IF_EXCEPTION(scope, {});
    context.wrapper.set_slot_timing(vm, result);
    return result;
}

JSValue bunBindgenCpp_WebCorePerformance_Performance_getter_timing(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_getter_timing_Arguments&)
{
    return performanceTiming(context);
}

std::optional<JSValue> bunBindgenCpp_WebCorePerformance_Performance_getter_onresourcetimingbufferfull(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_getter_onresourcetimingbufferfull_Arguments&)
{
    return eventHandlerAttribute(
        context.wrapped(),
        eventNames().resourcetimingbufferfullEvent,
        worldForDOMObject(context.wrapper));
}

void bunBindgenCpp_WebCorePerformance_Performance_setter_onresourcetimingbufferfull(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_setter_onresourcetimingbufferfull_Arguments& args)
{
    setEventHandlerAttribute<JSEventListener>(
        context.globalObject,
        context.wrapped(),
        eventNames().resourcetimingbufferfullEvent,
        args.value,
        context.wrapper);
}

PerformanceJSONDictionaryResult bunBindgenCpp_WebCorePerformance_Performance_method_toJSON(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_toJSON_Arguments&)
{
    auto& global = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto timing = performanceTiming(context);
    RETURN_IF_EXCEPTION(scope, {});
    return {
        .timeOrigin = context.wrapped().timeOrigin(),
        .timing = timing,
    };
}

CppResultSequence<JSValue> bunBindgenCpp_WebCorePerformance_Performance_method_getEntries(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_getEntries_Arguments&)
{
    return performanceEntriesResult(context, context.wrapped().getEntries());
}

CppResultSequence<JSValue> bunBindgenCpp_WebCorePerformance_Performance_method_getEntriesByType(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_getEntriesByType_Arguments& args)
{
    return performanceEntriesResult(context, context.wrapped().getEntriesByType(args.type));
}

CppResultSequence<JSValue> bunBindgenCpp_WebCorePerformance_Performance_method_getEntriesByName(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_getEntriesByName_Arguments& args)
{
    return performanceEntriesResult(
        context,
        context.wrapped().getEntriesByName(args.name, args.type.value_or(String {})));
}

void bunBindgenCpp_WebCorePerformance_Performance_method_clearResourceTimings(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_clearResourceTimings_Arguments&)
{
    context.wrapped().clearResourceTimings();
}

void bunBindgenCpp_WebCorePerformance_Performance_method_setResourceTimingBufferSize(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_setResourceTimingBufferSize_Arguments& args)
{
    context.wrapped().setResourceTimingBufferSize(args.maxSize);
}

static PerformanceMarkOptions performanceMarkOptions(
    const std::optional<PerformanceMarkOptionsDictionary>& input)
{
    PerformanceMarkOptions result;
    result.detail = input ? input->detail : jsUndefined();
    if (input)
        result.startTime = input->start_time;
    return result;
}

JSValue bunBindgenCpp_WebCorePerformance_Performance_method_mark(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_mark_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    return performanceEntryToJS(
        context,
        scope,
        context.wrapped().mark(
            context.globalObject,
            args.markName,
            std::optional { performanceMarkOptions(args.markOptions) }));
}

void bunBindgenCpp_WebCorePerformance_Performance_method_clearMarks(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_clearMarks_Arguments& args)
{
    context.wrapped().clearMarks(args.markName.value_or(String {}));
}

template<typename Value>
static std::variant<String, double> performanceMarkOrTimestamp(const Value& input)
{
    using Tag = typename Value::Tag;
    switch (input.tag()) {
    case Tag::mark:
        return String(input.mark());
    case Tag::timestamp:
        return input.timestamp();
    case Tag::none:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static PerformanceMeasureOptions performanceMeasureOptions(
    const PerformanceMeasureOptionsDictionary& input)
{
    PerformanceMeasureOptions result;
    result.detail = input.detail;
    if (input.start)
        result.start = performanceMarkOrTimestamp(*input.start);
    result.duration = input.duration;
    if (input.end)
        result.end = performanceMarkOrTimestamp(*input.end);
    return result;
}

template<typename Value>
static std::optional<Performance::StartOrMeasureOptions> performanceStartOrMeasureOptions(
    const std::optional<Value>& input)
{
    if (!input)
        return std::nullopt;
    using Tag = typename Value::Tag;
    switch (input->tag()) {
    case Tag::mark:
        return String(input->mark());
    case Tag::options:
        return performanceMeasureOptions(input->options());
    case Tag::none:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSValue bunBindgenCpp_WebCorePerformance_Performance_method_measure(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_measure_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    return performanceEntryToJS(
        context,
        scope,
        context.wrapped().measure(
            context.globalObject,
            args.measureName,
            performanceStartOrMeasureOptions(args.startOrMeasureOptions),
            args.endMark.value_or(String {})));
}

void bunBindgenCpp_WebCorePerformance_Performance_method_clearMeasures(
    CppEngineCallContext<JSPerformance>& context,
    const BunBindgenCpp_WebCorePerformance_Performance_method_clearMeasures_Arguments& args)
{
    context.wrapped().clearMeasures(args.measureName.value_or(String {}));
}

void bunBindgenCpp_WebCorePerformance_Performance_method_markResourceTiming(
    CppEngineCallContext<JSPerformance>&,
    const BunBindgenCpp_WebCorePerformance_Performance_method_markResourceTiming_Arguments&)
{
}

} // namespace Bun::Bindgen::Cpp
