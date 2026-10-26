#include "ErrorCode.h"
#include "Bindgen/IDLConvertBase.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "root.h"

#include "JSNodePerformanceHooksHistogramPrototype.h"
#include "JSNodePerformanceHooksHistogram.h"
#include "wtf/text/ASCIILiteral.h"
#include <wtf/MathExtras.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>

namespace Bun {

using namespace JSC;

static JSNodePerformanceHooksHistogram* performanceHistogram(JSC::JSValue value)
{
    auto* histogram = dynamicDowncast<JSNodePerformanceHooksHistogram>(value);
    RELEASE_ASSERT(histogram);
    return histogram;
}

#define BUN_BINDGEN_OBJECT_SURFACE_JSNodePerformanceHooksHistogramPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSNodePerformanceHooksHistogramPrototype

const ClassInfo JSNodePerformanceHooksHistogramPrototype::s_info = { "RecordableHistogram"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSNodePerformanceHooksHistogramPrototype) };

void JSNodePerformanceHooksHistogramPrototype::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSNodePerformanceHooksHistogramPrototype_install(vm, JSNodePerformanceHooksHistogram::info(), *this);
}

void Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramRecord(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramRecord_Arguments& args)
{
    performanceHistogram(args.bindingThis)->record(args.value.is_number() ? args.value.number() : args.value.bigint());
}

void Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramRecordDelta(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramRecordDelta_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    performanceHistogram(args.bindingThis)->recordDelta(globalObject);
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramAdd(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramAdd_Arguments& args)
{
    return performanceHistogram(args.bindingThis)->add(performanceHistogram(args.other));
}

void Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramReset(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramReset_Arguments& args)
{
    performanceHistogram(args.bindingThis)->reset();
}

static double toPercentile(JSC::ThrowScope& scope, JSGlobalObject* globalObject, double percentile)
{
    if (percentile <= 0 || percentile > 100 || std::isnan(percentile)) {
        Bun::ERR::OUT_OF_RANGE(scope, globalObject, "percentile"_s, "> 0 && <= 100"_s, jsNumber(percentile));
        return {};
    }
    return percentile;
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramPercentile(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramPercentile_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    double percentile = toPercentile(scope, globalObject, args.percentile);
    RETURN_IF_EXCEPTION(scope, {});

    return static_cast<double>(performanceHistogram(args.bindingThis)->getPercentile(percentile));
}

int64_t Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramPercentileBigInt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramPercentileBigInt_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    double percentile = toPercentile(scope, globalObject, args.percentile);
    RETURN_IF_EXCEPTION(scope, {});

    return performanceHistogram(args.bindingThis)->getPercentile(percentile);
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_count(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_count_Arguments& args)
{
    return static_cast<double>(performanceHistogram(args.bindingThis)->getCount());
}

uint64_t Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_countBigInt(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_countBigInt_Arguments& args)
{
    return performanceHistogram(args.bindingThis)->getCount();
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_min(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_min_Arguments& args)
{
    int64_t minValue = performanceHistogram(args.bindingThis)->getMin();

    // Node.js returns the value as if it were unsigned when converting to double
    // This handles the special case where the initial value is INT64_MIN
    return static_cast<double>(static_cast<uint64_t>(minValue));
}

int64_t Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_minBigInt(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_minBigInt_Arguments& args)
{
    // Node.js returns different initial values for min vs minBigInt
    // min returns 9223372036854776000 (as double)
    // minBigInt returns 9223372036854775807n (INT64_MAX)
    auto* histogram = performanceHistogram(args.bindingThis);
    return histogram->getCount() == 0 ? INT64_MAX : histogram->getMin();
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_max(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_max_Arguments& args)
{
    return static_cast<double>(performanceHistogram(args.bindingThis)->getMax());
}

int64_t Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_maxBigInt(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_maxBigInt_Arguments& args)
{
    return performanceHistogram(args.bindingThis)->getMax();
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_mean(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_mean_Arguments& args)
{
    return performanceHistogram(args.bindingThis)->getMean();
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_stddev(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_stddev_Arguments& args)
{
    return performanceHistogram(args.bindingThis)->getStddev();
}

double Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_exceeds(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_exceeds_Arguments& args)
{
    return static_cast<double>(performanceHistogram(args.bindingThis)->getExceeds());
}

uint64_t Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_exceedsBigInt(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_exceedsBigInt_Arguments& args)
{
    return static_cast<uint64_t>(performanceHistogram(args.bindingThis)->getExceeds());
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_percentiles(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_percentiles_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSMap* map = JSMap::create(vm, globalObject->mapStructure());
    performanceHistogram(args.bindingThis)->getPercentiles(globalObject, map);
    RETURN_IF_EXCEPTION(scope, {});
    return map;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_percentilesBigInt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_percentilesBigInt_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSMap* map = JSMap::create(vm, globalObject->mapStructure());
    performanceHistogram(args.bindingThis)->getPercentilesBigInt(globalObject, map);
    RETURN_IF_EXCEPTION(scope, {});
    return map;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_createHistogram(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_createHistogram_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    int64_t lowest = args.lowest ? (args.lowest->is_number() ? args.lowest->number() : args.lowest->bigint()) : 1;
    int64_t highest = args.highest ? (args.highest->is_number() ? args.highest->number() : args.highest->bigint()) : std::numeric_limits<int64_t>::max();
    int32_t figures = args.figures.value_or(3);

    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    Structure* structure = zigGlobalObject->m_JSNodePerformanceHooksHistogramClassStructure.get(zigGlobalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSNodePerformanceHooksHistogram* histogram = JSNodePerformanceHooksHistogram::create(vm, structure, globalObject, lowest, highest, figures);
    RETURN_IF_EXCEPTION(scope, {});

    return histogram;
}

// Create histogram for event loop delay monitoring
JSC::JSValue Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_monitorEventLoopDelay(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_monitorEventLoopDelay_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Create histogram with range for event loop delays (1ns to 1 hour)
    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    Structure* structure = zigGlobalObject->m_JSNodePerformanceHooksHistogramClassStructure.get(zigGlobalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSNodePerformanceHooksHistogram* histogram = JSNodePerformanceHooksHistogram::create(
        vm, structure, globalObject,
        1, // lowest: 1 nanosecond
        3600000000000LL, // highest: 1 hour in nanoseconds
        3 // figures: 3 significant digits
    );

    RETURN_IF_EXCEPTION(scope, {});

    return histogram;
}

// Enable event loop delay monitoring
void Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_enableEventLoopDelay(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_enableEventLoopDelay_Arguments& args)
{
    auto* globalObject = &context.globalObject;

    // Reset histogram data on enable
    performanceHistogram(args.histogram)->reset();

    // Enable the event loop delay monitor in Timer.zig
    Bun::Bindgen::ZigExports::bunBindgenZig_PerformanceHistogram_enableEventLoopDelayMonitoring(globalObject, args.histogram, args.resolution);
}

// Disable event loop delay monitoring
void Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_disableEventLoopDelay(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_disableEventLoopDelay_Arguments&)
{
    auto* globalObject = &context.globalObject;

    // Call into Zig to disable monitoring
    Bun::Bindgen::ZigExports::bunBindgenZig_PerformanceHistogram_disableEventLoopDelayMonitoring(globalObject);
}

void Bun::Bindgen::Engine::bunBindgenEngine_PerformanceHistogram_recordDelay(
    Bun::Bindgen::EngineCallContext&,
    const Bun::Bindgen::Engine::BunBindgenEngine_PerformanceHistogram_recordDelay_Arguments& args)
{
    if (args.delay <= 0) return;

    performanceHistogram(args.histogram)->record(args.delay);
}

} // namespace Bun
