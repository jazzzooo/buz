#include "root.h"
#include "JSDOMExceptionHandling.h"

#include "ExceptionOr.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "MessagePort.h"
#include "SerializedScriptValue.h"
#include "SchemaBindings.h"
#include "CodeCoverageSnapshot.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/AggregateError.h>
#include <JavaScriptCore/BytecodeIndex.h>
#include <JavaScriptCore/ClassInfo.h>
#include <JavaScriptCore/CodeBlock.h>
#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/DeferTermination.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/HeapSnapshotBuilder.h>
#include <JavaScriptCore/JIT.h>
#include <JavaScriptCore/JSBasePrivate.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JavaScript.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SamplingProfiler.h>
#include <JavaScriptCore/TestRunnerUtils.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <algorithm>
#include <cstddef>
#include <memory>
#include "../../libc_sys/BunProcessMemory.h"
#include "wtf-bindings.h"
#include <wtf/FileSystem.h>
#include <wtf/MemoryFootprint.h>
#include <wtf/TimeZone.h>
#include <wtf/text/WTFString.h>
#include <wtf/text/MakeString.h>

#if USE(BMALLOC_MEMORY_FOOTPRINT_API)
#include <bmalloc/bmalloc.h>
#endif

#include "BunProcess.h"
#include <JavaScriptCore/SourceProviderCache.h>
#if ENABLE(REMOTE_INSPECTOR)
#include <JavaScriptCore/RemoteInspectorServer.h>
#endif

#include "ZigSourceProvider.h"
#include "mimalloc-stats.h"

#include <JavaScriptCore/ControlFlowProfiler.h>

#if OS(DARWIN)
#if ASSERT_ENABLED
#if !__has_feature(address_sanitizer)
#include <malloc/malloc.h>
#define IS_MALLOC_DEBUGGING_ENABLED 1
#endif
#endif
#endif

using namespace JSC;
using namespace WTF;
using namespace WebCore;

namespace Bun {

static JSValue parseMimallocJSON(JSGlobalObject* globalObject, char* data)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    std::unique_ptr<char, decltype(&mi_free)> json(data, &mi_free);
    if (!json) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto result = JSONParse(globalObject, String::fromUTF8(json.get()));
    RETURN_IF_EXCEPTION(scope, {});
    if (result.isEmpty()) {
        throwTypeError(globalObject, scope, "Allocator returned invalid JSON"_s);
        return {};
    }
    return result;
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_startRemoteDebugger(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_startRemoteDebugger_Arguments& args)
{
#if ENABLE(REMOTE_INSPECTOR)
    static constexpr auto defaultHost = "127.0.0.1";
    static constexpr uint16_t defaultPort = 9230;

    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    const char* host = defaultHost;
    WTF::CString hostCString;
    if (args.host && !args.host->isEmpty()) {
        hostCString = toCString(*args.host);
        if (!hostCString.isNull())
            host = hostCString.span().data();
    }

    uint16_t port = args.port ? static_cast<uint16_t>(*args.port) : defaultPort;

    globalObject->setInspectable(true);
    auto& server = Inspector::RemoteInspectorServer::singleton();
    if (!server.start(reinterpret_cast<const char*>(host), port)) {
        throwVMError(
            globalObject, scope,
            createError(globalObject,
                makeString("Failed to start server \""_s,
                    String::fromLatin1(host),
                    ":"_s, port, "\". Is port already in use?"_s)));
        return;
    }
    scope.release();
#else
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    throwVMError(globalObject, scope,
        createTypeError(
            globalObject,
            "Remote inspector is not enabled in this build of Bun"_s));
#endif
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_jscDescribe(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_jscDescribe_Arguments& args)
{
    if (!args.value)
        return std::nullopt;
    return WTF::toString(*args.value);
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_jscDescribeArray(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_jscDescribeArray_Arguments& args)
{
    if (!args.value)
        return std::nullopt;
    auto* object = dynamicDowncast<JSC::JSObject>(*args.value);
    if (!object)
        return "<not object>"_s;
    return WTF::toString("<Butterfly: ", RawPointer(object->butterfly()),
        "; public length: ", object->getArrayLength(),
        "; vector length: ", object->getVectorLength(), ">");
}

uint64_t Bindgen::Cpp::bunBindgenCpp_BunJSCModule_gcAndSweep(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_gcAndSweep_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    JSLockHolder lock(vm);
    vm.heap.collectNow(Sync, CollectionScope::Full);
    return vm.heap.sizeAfterLastFullCollection();
}

uint64_t Bindgen::Cpp::bunBindgenCpp_BunJSCModule_fullGC(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_fullGC_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    JSLockHolder lock(vm);
    vm.heap.collectSync(CollectionScope::Full);
    return vm.heap.sizeAfterLastFullCollection();
}

uint64_t Bindgen::Cpp::bunBindgenCpp_BunJSCModule_edenGC(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_edenGC_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    JSLockHolder lock(vm);
    vm.heap.collectSync(CollectionScope::Eden);
    return vm.heap.sizeAfterLastEdenCollection();
}

uint64_t Bindgen::Cpp::bunBindgenCpp_BunJSCModule_heapSize(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_heapSize_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    JSLockHolder lock(vm);
    return vm.heap.size();
}

Bindgen::BunJSCHeapStatsDictionaryResult Bindgen::Cpp::bunBindgenCpp_BunJSCModule_heapStats(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_heapStats_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (vm.heap.size() == 0) {
        vm.heap.collectNow(Sync, CollectionScope::Full);
    }

    const auto createdSortedTypeCounts = [&](JSC::TypeCountSet const& typeCounts) {
        WTF::Vector<std::pair<WTF::String, uint32_t>> counts;
        counts.reserveInitialCapacity(typeCounts.size());
        for (auto& it : typeCounts) {
            if (it.value > 0)
                counts.append(std::make_pair(WTF::String(it.key), static_cast<uint32_t>(it.value)));
        }

        // Sort by count first, then by name.
        std::sort(counts.begin(), counts.end(),
            [](const auto& a, const auto& b) {
                if (a.second == b.second) {
                    WTF::StringView left = a.first;
                    WTF::StringView right = b.first;
                    unsigned originalLeftLength = left.length();
                    unsigned originalRightLength = right.length();
                    unsigned size = std::min(left.length(), right.length());
                    left = left.substring(0, size);
                    right = right.substring(0, size);
                    std::strong_ordering result = WTF::codePointCompare(right, left);
                    if (result == std::strong_ordering::equal) {
                        return originalLeftLength > originalRightLength;
                    }

                    return result == std::strong_ordering::greater;
                }

                return a.second > b.second;
            });
        return counts;
    };

    Bindgen::BunJSCHeapStatsDictionaryResult result {
        .object_type_counts = createdSortedTypeCounts(Bindgen::heapObjectTypeCounts(vm, false)),
        .protected_object_type_counts = createdSortedTypeCounts(Bindgen::heapObjectTypeCounts(vm, true)),
        .heap_size = vm.heap.size(),
        .heap_capacity = vm.heap.capacity(),
        .extra_memory_size = vm.heap.extraMemorySize(),
        .object_count = vm.heap.objectCount(),
        .protected_object_count = vm.heap.protectedObjectCount(),
        .global_object_count = vm.heap.globalObjectCount(),
        .protected_global_object_count = vm.heap.protectedGlobalObjectCount(),
    };

#if IS_MALLOC_DEBUGGING_ENABLED
#if OS(DARWIN)
    {
        vm_address_t* zones;
        unsigned count;

        // Zero out the structures in case a zone is missing
        malloc_statistics_t zone_stats;
        zone_stats.blocks_in_use = 0;
        zone_stats.size_in_use = 0;
        zone_stats.max_size_in_use = 0;
        zone_stats.size_allocated = 0;

        malloc_zone_pressure_relief(nullptr, 0);
        malloc_get_all_zones(mach_task_self(), 0, &zones, &count);
        WTF::Vector<std::pair<WTF::String, uint64_t>> zoneSizes;
        zoneSizes.reserveInitialCapacity(count);
        for (unsigned i = 0; i < count; i++) {
            auto zone = reinterpret_cast<malloc_zone_t*>(zones[i]);
            if (const char* name = malloc_get_zone_name(zone)) {
                malloc_zone_statistics(reinterpret_cast<malloc_zone_t*>(zones[i]),
                    &zone_stats);
                zoneSizes.append(std::make_pair(String::fromUTF8(name), zone_stats.size_in_use));
            }
        }

        std::sort(zoneSizes.begin(), zoneSizes.end(),
            [](const auto& a, const auto& b) {
                // Sort by name if the sizes are the same.
                if (a.second == b.second) {
                    WTF::StringView left = a.first;
                    WTF::StringView right = b.first;
                    unsigned originalLeftLength = left.length();
                    unsigned originalRightLength = right.length();
                    unsigned size = std::min(left.length(), right.length());
                    left = left.substring(0, size);
                    right = right.substring(0, size);
                    std::strong_ordering result = WTF::codePointCompare(right, left);
                    if (result == std::strong_ordering::equal) {
                        return originalLeftLength > originalRightLength;
                    }

                    return result == std::strong_ordering::greater;
                }

                return a.second > b.second;
            });
        result.zones = WTF::move(zoneSizes);
    }
#endif
#endif

    mi_collect(false);
    result.mimalloc = parseMimallocJSON(globalObject, mi_stats_get_json(0, nullptr));
    RETURN_IF_EXCEPTION(scope, {});

    bool includeDump = false;
    bool includeBlocks = false;
    if (args.dump && args.dump->is_options()) {
        const auto& dump = args.dump->options().dump;
        if (dump.is_string()) {
            includeDump = !dump.string().isEmpty();
            includeBlocks = dump.string() == "blocks"_s;
        } else {
            includeDump = dump.truthy();
        }
    }
    if (includeDump) {
#if BUN_DEBUG
        const bool hashAddresses = false;
#else
        const bool hashAddresses = true;
#endif
        result.mimalloc_dump = parseMimallocJSON(globalObject, mi_heap_dump_json(includeBlocks, hashAddresses));
        RETURN_IF_EXCEPTION(scope, {});
    }

    return result;
}

Bindgen::BunJSCMemoryUsageDictionaryResult Bindgen::Cpp::bunBindgenCpp_BunJSCModule_memoryUsage(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_memoryUsage_Arguments&)
{
    size_t elapsed_msecs = 0;
    size_t user_msecs = 0;
    size_t system_msecs = 0;
    size_t current_rss = 0;
    size_t peak_rss = 0;
    size_t current_commit = 0;
    size_t peak_commit = 0;
    size_t page_faults = 0;

    mi_process_info(&elapsed_msecs, &user_msecs, &system_msecs, &current_rss,
        &peak_rss, &current_commit, &peak_commit, &page_faults);

    // mi_process_info produces incorrect rss size on linux.
    bun_process_resident_memory(&current_rss);

    return {
        .current = current_rss,
        .peak = peak_rss,
        .current_commit = current_commit,
        .peak_commit = peak_commit,
        .page_faults = page_faults,
    };
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_noInline(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_noInline_Arguments& args)
{
    if (auto* executable = args.function ? JSC::getExecutableForFunction(*args.function) : nullptr)
        executable->setNeverInline(true);
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_startSamplingProfiler(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_startSamplingProfiler_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    JSC::SamplingProfiler& samplingProfiler = vm.ensureSamplingProfiler(WTF::Stopwatch::create());

    auto scope = DECLARE_THROW_SCOPE(vm);
    if (args.directory && args.directory->is_path()) {
        const auto& path = args.directory->path();
        if (!path.isEmpty()) {
            auto pathCString = toCString(String(path));
            auto created = Bun::Bindgen::ZigExports::bunBindgenZig_NodeFS_mkdirRecursive(path);
            RETURN_IF_EXCEPTION(scope, void());
            if (!created) {
                throwOutOfMemoryError(globalObject, scope);
                return;
            }
            if (!*created) {
                throwVMError(
                    globalObject, scope,
                    createTypeError(globalObject, "directory couldn't be created"_s));
                return;
            }

            Options::samplingProfilerPath() = pathCString.span().data();
            samplingProfiler.registerForReportAtExit();
        }
    }
    if (args.sampleInterval && *args.sampleInterval && **args.sampleInterval) {
        samplingProfiler.setTimingInterval(
            Seconds::fromMicroseconds(**args.sampleInterval));
    }

    samplingProfiler.noticeCurrentThreadAsJSCExecutionThread();
    samplingProfiler.start();
    scope.release();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunJSCModule_samplingProfilerStackTraces(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_samplingProfilerStackTraces_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    JSC::DeferTermination deferScope(vm);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!vm.samplingProfiler()) {
        throwException(globalObject, scope,
            createError(globalObject, "Sampling profiler was never started"_s));
        return {};
    }

    WTF::String jsonString = vm.samplingProfiler()->stackTracesAsJSON()->toJSONString();
    JSC::JSValue result = JSONParse(globalObject, jsonString);
    scope.releaseAssertNoException();
    return result;
}

double Bindgen::Cpp::bunBindgenCpp_BunJSCModule_getRandomSeed(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_getRandomSeed_Arguments&)
{
    auto* globalObject = &context.globalObject;
    return globalObject->weakRandom().seed();
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_setRandomSeed(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_setRandomSeed_Arguments& args)
{
    context.globalObject.weakRandom().setSeed(args.seed);
}

bool Bindgen::Cpp::bunBindgenCpp_BunJSCModule_isRope(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_isRope_Arguments& args)
{
    if (!args.value)
        return false;
    return !JSC::asString(*args.value)->tryGetValueImpl();
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_callerSourceOrigin(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_callerSourceOrigin_Arguments&)
{
    RELEASE_ASSERT(context.callerSourceOrigin);
    const auto& sourceOrigin = *context.callerSourceOrigin;
    if (sourceOrigin.url().isNull())
        return std::nullopt;
    return sourceOrigin.string();
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_noFTL(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_noFTL_Arguments& args)
{
    if (auto* executable = args.function ? JSC::getExecutableForFunction(*args.function) : nullptr)
        executable->setNeverFTLOptimize(true);
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_noOSRExitFuzzing(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_noOSRExitFuzzing_Arguments& args)
{
    if (auto* executable = args.function ? JSC::getExecutableForFunction(*args.function) : nullptr)
        executable->setCanUseOSRExitFuzzing(false);
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_optimizeNextInvocation(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_optimizeNextInvocation_Arguments& args)
{
#if ENABLE(JIT)
    if (auto* codeBlock = args.function ? JSC::getSomeBaselineCodeBlockForFunction(*args.function) : nullptr)
        codeBlock->optimizeNextInvocation();
#else
    UNUSED_PARAM(args);
#endif
}

std::optional<double> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_numberOfDFGCompiles(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_numberOfDFGCompiles_Arguments& args)
{
    if (!args.function)
        return std::nullopt;
    auto* codeBlock = JSC::getSomeBaselineCodeBlockForFunction(*args.function);
    if (!codeBlock)
        return 0;

#if ENABLE(DFG_JIT)
    if (Options::useJIT() && Options::useBaselineJIT() && Options::useDFGJIT())
        return codeBlock->numberOfDFGCompiles();
#endif
    return 1000000;
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_releaseWeakRefs(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_releaseWeakRefs_Arguments&)
{
    context.globalObject.vm().finalizeSynchronousJSExecution();
}

double Bindgen::Cpp::bunBindgenCpp_BunJSCModule_totalCompileTime(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_totalCompileTime_Arguments&)
{
    return JIT::totalCompileTime().milliseconds();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunJSCModule_getProtectedObjects(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_getProtectedObjects_Arguments&)
{
    auto* globalObject = &context.globalObject;
    MarkedArgumentBuffer list;
    globalObject->vm().heap.forEachProtectedCell(
        [&](JSCell* cell) { list.append(cell); });
    RELEASE_ASSERT(!list.hasOverflowed());
    return constructArray(globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), list);
}

std::optional<double> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_reoptimizationRetryCount(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_reoptimizationRetryCount_Arguments& args)
{
    if (!args.function)
        return std::nullopt;
    auto* codeBlock = JSC::getSomeBaselineCodeBlockForFunction(*args.function);
    if (!codeBlock)
        return 0;
    return codeBlock->reoptimizationRetryCounter();
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_drainMicrotasks(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_drainMicrotasks_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    vm.drainMicrotasks();
    RETURN_IF_EXCEPTION(scope, void());
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_tickEventLoop(globalObject);
    RETURN_IF_EXCEPTION(scope, void());
    scope.release();
}

WTF::String Bindgen::Cpp::bunBindgenCpp_BunJSCModule_setTimeZone(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_setTimeZone_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    PreparedTimeZoneOverride prepared;
    switch (prepared.prepare(args.timeZone)) {
    case PreparedTimeZoneOverride::Result::Invalid: {
        auto message = tryMakeString("Invalid timezone: \""_s, args.timeZone, "\""_s);
        if (message.isNull()) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        throwTypeError(globalObject, scope, message);
        return {};
    }
    case PreparedTimeZoneOverride::Result::OutOfMemory:
        throwOutOfMemoryError(globalObject, scope);
        return {};
    case PreparedTimeZoneOverride::Result::Valid:
        break;
    }
    auto identifier = prepared.identifier();
    std::span<UChar> characters;
    auto timeZoneString = WTF::String::tryCreateUninitialized(identifier.size(), characters);
    if (timeZoneString.isNull()) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    for (size_t i = 0; i < identifier.size(); ++i)
        characters[i] = identifier[i];
    prepared.commit();
    WTF::timeZoneDidChange();
    vm.dateCache.clearForTimeZoneChange();
    scope.release();
    return timeZoneString;
}

static JSC::JSValue finishSamplingProfile(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& samplingProfiler = *vm.samplingProfiler();
    StringPrintStream topFunctions;
    samplingProfiler.reportTopFunctions(topFunctions);

    StringPrintStream byteCodes;
    samplingProfiler.reportTopBytecodes(byteCodes);

    JSValue stackTraces = JSONParse(globalObject, samplingProfiler.stackTracesAsJSON()->toJSONString());

    {
        auto& lock = samplingProfiler.getLock();
        WTF::Locker locker { lock };
        samplingProfiler.pause();
        samplingProfiler.clearData();
    }
    RETURN_IF_EXCEPTION(throwScope, {});

    JSObject* result = constructEmptyObject(globalObject, globalObject->objectPrototype(), 3);
    result->putDirect(vm, Identifier::fromString(vm, "functions"_s), jsString(vm, topFunctions.toString()));
    result->putDirect(vm, Identifier::fromString(vm, "bytecodes"_s), jsString(vm, byteCodes.toString()));
    result->putDirect(vm, Identifier::fromString(vm, "stackTraces"_s), stackTraces);
    return result;
}

static void abandonSamplingProfile(JSC::VM& vm)
{
    if (auto* samplingProfiler = vm.samplingProfiler()) {
        auto& lock = samplingProfiler->getLock();
        WTF::Locker locker { lock };
        samplingProfiler->pause();
        samplingProfiler->clearData();
    }
}

Bindgen::BunJSCProfileResult Bindgen::Cpp::bunBindgenCpp_BunJSCModule_profile(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_profile_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& samplingProfiler = vm.ensureSamplingProfiler(WTF::Stopwatch::create());
    const uint32_t sampleInterval = args.sampleInterval && *args.sampleInterval
        ? **args.sampleInterval
        : 1000;
    samplingProfiler.setTimingInterval(Seconds::fromMicroseconds(sampleInterval));

    MarkedArgumentBuffer callbackArguments;
    callbackArguments.ensureCapacity(args.arguments.size());
    for (auto argument : args.arguments)
        argument.appendTo(callbackArguments);
    if (callbackArguments.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, throwScope);
        return {};
    }

    JSC::CallData callData = JSC::getCallData(args.callback);

    samplingProfiler.noticeCurrentThreadAsJSCExecutionThread();
    samplingProfiler.start();
    JSValue returnValue = JSC::profiledCall(
        globalObject, ProfilingReason::API, args.callback, callData, JSC::jsUndefined(), callbackArguments);

    if (returnValue.isEmpty() || throwScope.exception()) {
        abandonSamplingProfile(vm);
        return {};
    }

    if (auto* promise = dynamicDowncast<JSPromise>(returnValue)) {
        auto afterOngoingPromiseCapability = JSC::JSPromise::create(vm, globalObject->promiseStructure());
        RETURN_IF_EXCEPTION(throwScope, {});

        auto* resolve = JSFunction::create(vm, globalObject, 0, "resolve"_s,
            bun_bindgen_host_BunJSCModule_profileResolve, ImplementationVisibility::Private);
        auto* reject = JSFunction::create(vm, globalObject, 0, "reject"_s,
            bun_bindgen_host_BunJSCModule_profileReject, ImplementationVisibility::Private);
        promise->performPromiseThen(vm, globalObject, resolve, reject, afterOngoingPromiseCapability);
        RETURN_IF_EXCEPTION(throwScope, {});
        Bindgen::BunJSCProfileResult result;
        result.set_promise(afterOngoingPromiseCapability);
        return result;
    }

    JSValue profile = finishSamplingProfile(vm, globalObject);
    RETURN_IF_EXCEPTION(throwScope, {});
    throwScope.release();
    Bindgen::BunJSCProfileResult result;
    result.set_profile(profile);
    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunJSCModule_profileResolve(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_profileResolve_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue result = finishSamplingProfile(vm, globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    auto* promise = JSPromise::resolvedPromise(globalObject, result);
    RETURN_IF_EXCEPTION(scope, {});
    scope.release();
    return promise;
}

void Bindgen::Cpp::bunBindgenCpp_BunJSCModule_profileReject(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_profileReject_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    abandonSamplingProfile(vm);
    throwException(globalObject, scope, args.error.value_or(jsUndefined()));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunJSCModule_generateHeapSnapshotForDebugging(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_generateHeapSnapshotForDebugging_Arguments&)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    JSLockHolder lock(vm);
    DeferTermination deferScope(vm);
    auto scope = DECLARE_THROW_SCOPE(vm);

    Bun::Bindgen::ZigExports::bunBindgenZig_Analytics_recordHeapSnapshot();

    String jsonString;
    {
        DeferGCForAWhile deferGC(vm); // Prevent concurrent GC from interfering with
                                      // the full GC that the snapshot does.

        HeapSnapshotBuilder snapshotBuilder(
            vm.ensureHeapProfiler(),
            HeapSnapshotBuilder::SnapshotType::GCDebuggingSnapshot);
        snapshotBuilder.buildSnapshot();

        jsonString = snapshotBuilder.json();
    }
    scope.releaseAssertNoException();

    return JSONParse(globalObject, WTF::move(jsonString));
}

Bindgen::BunJSCSerializeResult Bindgen::Cpp::bunBindgenCpp_BunJSCModule_serialize(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_serialize_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = uncheckedDowncast<JSDOMGlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    Vector<JSC::Strong<JSC::JSObject>> transferList;
    Vector<RefPtr<MessagePort>> dummyPorts;
    ExceptionOr<Ref<SerializedScriptValue>> serialized = SerializedScriptValue::create(
        *globalObject, args.value.value_or(jsUndefined()), WTF::move(transferList), dummyPorts,
        SerializationForStorage::Yes);
    EXCEPTION_ASSERT(serialized.hasException() == !!throwScope.exception());
    if (serialized.hasException()) {
        WebCore::propagateException(*globalObject, throwScope, serialized.releaseException());
        RELEASE_AND_RETURN(throwScope, {});
    }

    auto serializedValue = serialized.releaseReturnValue();
    auto arrayBuffer = serializedValue->toArrayBuffer();

    const bool asNodeBuffer = args.options && args.options->is_options()
        && args.options->options().binary_type
        && *args.options->options().binary_type == "nodebuffer"_s;
    if (asNodeBuffer) {
        size_t byteLength = arrayBuffer->byteLength();
        auto* subclassStructure = globalObject->JSBufferSubclassStructure();
        JSC::JSUint8Array* uint8Array = JSC::JSUint8Array::create(lexicalGlobalObject, subclassStructure, WTF::move(arrayBuffer), 0, byteLength);
        RETURN_IF_EXCEPTION(throwScope, {});
        throwScope.release();
        Bindgen::BunJSCSerializeResult result;
        result.set_node_buffer(uint8Array);
        return result;
    }

    JSC::JSValue value;
    if (arrayBuffer->isShared()) {
        value = JSArrayBuffer::create(vm, globalObject->arrayBufferStructureWithSharingMode<ArrayBufferSharingMode::Shared>(), WTF::move(arrayBuffer));
    } else {
        value = JSArrayBuffer::create(vm, globalObject->arrayBufferStructure(), WTF::move(arrayBuffer));
    }
    throwScope.release();
    Bindgen::BunJSCSerializeResult result;
    result.set_shared_array_buffer(value);
    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunJSCModule_deserialize(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_deserialize_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    return SerializedScriptValue::fromBytes(*globalObject, args.input);
}

Bindgen::BunJSCCodeCoverageResult Bindgen::Cpp::bunBindgenCpp_BunJSCModule_codeCoverageForFile(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_codeCoverageForFile_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto sourceID = Zig::sourceIDForSourceURL(args.filename);
    if (!sourceID) {
        throwException(globalObject, throwScope,
            createError(globalObject, "No source for file"_s));
        return {};
    }

    CodeCoverageSnapshot snapshot;
    if (!snapshot.collect(vm, sourceID)) {
        throwOutOfMemoryError(globalObject, throwScope);
        return {};
    }

    if (snapshot.blocks.isEmpty() && snapshot.functions.isEmpty()) {
        auto* empty = JSC::constructEmptyArray(globalObject, nullptr, 0);
        RETURN_IF_EXCEPTION(throwScope, {});
        throwScope.release();
        Bindgen::BunJSCCodeCoverageResult result;
        result.set_empty(empty);
        return result;
    }

    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_code_coverage_byteRangeMappingFindExecutedLines(
        globalObject, args.filename, snapshot.blocks.span(), snapshot.functions.span(), args.ignoreSourceMap);
    RETURN_IF_EXCEPTION(throwScope, {});
    throwScope.release();
    Bindgen::BunJSCCodeCoverageResult output;
    if (result)
        output.set_mapping(WTF::move(*result));
    else
        output.set_missing(true);
    return output;
}

uint64_t Bindgen::Cpp::bunBindgenCpp_BunJSCModule_estimateShallowMemoryUsageOf(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_estimateShallowMemoryUsageOf_Arguments& args)
{
    if (!args.value)
        return 0;
    JSC::EnsureStillAliveScope alive = *args.value;
    return alive.value().asCell()->estimatedSizeInBytes(context.globalObject.vm());
}

#if USE(BMALLOC_MEMORY_FOOTPRINT_API)

std::optional<double> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_percentAvailableMemoryInUse(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_percentAvailableMemoryInUse_Arguments&)
{
    return bmalloc::api::percentAvailableMemoryInUse();
}

#else

std::optional<double> Bindgen::Cpp::bunBindgenCpp_BunJSCModule_percentAvailableMemoryInUse(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_BunJSCModule_percentAvailableMemoryInUse_Arguments&)
{
    return std::nullopt;
}

#endif

} // namespace Bun
