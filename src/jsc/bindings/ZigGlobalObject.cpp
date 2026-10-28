#include "root.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "BunPanic.h"
#include "ResolvedSource.h"
#include "ZigGlobalObject.h"
#include "helpers.h"
#include "JavaScriptCore/AsyncContextSwapScope.h"
#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/JSCellButterfly.h"
#include "wtf/text/Base64.h"
#include "JavaScriptCore/BuiltinNames.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/TopExceptionScope.h"
#include "JavaScriptCore/ClassInfo.h"
#include "JavaScriptCore/CodeBlock.h"
#include "JavaScriptCore/Completion.h"
#include "JavaScriptCore/DeferredWorkTimer.h"
#include "JavaScriptCore/Error.h"
#include "JavaScriptCore/ErrorInstance.h"
#include "JavaScriptCore/Exception.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/FunctionConstructor.h"
#include "JavaScriptCore/FunctionPrototype.h"
#include "JavaScriptCore/GetterSetter.h"
#include "JavaScriptCore/GlobalObjectMethodTable.h"
#include "JavaScriptCore/Heap.h"
#include "JavaScriptCore/DeferGCInlines.h"
#include "JavaScriptCore/Identifier.h"
#include "JavaScriptCore/InitializeThreading.h"
#include "JavaScriptCore/InternalFieldTuple.h"
#include "JavaScriptCore/InternalFunction.h"
#include "JavaScriptCore/JSArray.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSGlobalProxyInlines.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/JSLock.h"
#include "JavaScriptCore/JSMap.h"
#include "JavaScriptCore/JSMicrotask.h"
#include "JavaScriptCore/MicrotaskQueue.h"
#include "JavaScriptCore/JSModuleLoader.h"
#include "JavaScriptCore/CyclicModuleRecord.h"
#include "JavaScriptCore/ModuleRegistryEntry.h"
#include "JavaScriptCore/JSModuleNamespaceObject.h"
#include "JavaScriptCore/JSModuleNamespaceObjectInlines.h"
#include "JavaScriptCore/JSModuleRecord.h"
#include "JavaScriptCore/JSNativeStdFunction.h"
#include "JavaScriptCore/JSObject.h"
#include "JavaScriptCore/JSObjectInlines.h"
#include "JavaScriptCore/JSPromise.h"
#include "JavaScriptCore/JSSourceCode.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/JSWeakMap.h"
#include "JavaScriptCore/LazyClassStructure.h"
#include "JavaScriptCore/LazyClassStructureInlines.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/JSBasePrivate.h"
#include "JavaScriptCore/ScriptExecutable.h"
#include "JavaScriptCore/ScriptFetchParameters.h"
#include "JavaScriptCore/SourceOrigin.h"
#include "JavaScriptCore/StackFrame.h"
#include "JavaScriptCore/StackVisitor.h"
#include "JavaScriptCore/VM.h"
#include "AddEventListenerOptions.h"
#include "AsyncContextFrame.h"
#include "BunClientData.h"
#include "BunObject.h"
#include "BunPlugin.h"
#include "BunProcess.h"
#include "BunSecureContextCache.h"
#include "ProcessIdentifier.h"
#include "BunWorkerGlobalScope.h"
#include "CallSite.h"
#include "CallSitePrototype.h"
#include "FormatStackTraceForJS.h"
#include "JSCommonJSModule.h"
#include "JSCommonJSExtensions.h"
#include "ConsoleObject.h"
#include "DOMWrapperWorld-class.h"
#include "ErrorStackTrace.h"
#include "EventTargetOwner.h"
#include "ImportMetaObject.h"
#include "JSAbortController.h"
#include "JSAbortSignal.h"
#include "JSBroadcastChannel.h"
#include "JSBuffer.h"
#include "JSCloseEvent.h"
#include "JSCommonJSExtensions.h"
#include "JSCustomEvent.h"
#include "JSDOMException.h"
#include "JSDOMFormData.h"
#include "JSDOMURL.h"
#include "JSEnvironmentVariableMap.h"
#include "JSErrorEvent.h"
#include "JSEvent.h"
#include "JSEventEmitter.h"
#include "JSEventListener.h"
#include "JSEventTarget.h"
#include "JSFetchHeaders.h"
#include "JSFFIFunction.h"
#include "JSMessageEvent.h"
#include "JSMessagePort.h"
#include "JSNextTickQueue.h"
#include "JSPerformance.h"
#include "JSPerformanceEntry.h"
#include "JSPerformanceMark.h"
#include "JSPerformanceMeasure.h"
#include "JSPerformanceObserver.h"
#include "JSSocketAddressDTO.h"
#include "JSStringDecoder.h"
#include "JSURLSearchParams.h"
#include "JSWasmStreamingCompiler.h"
#include <JavaScriptCore/WebAssemblyCompileOptions.h>
#include "JSWebSocket.h"
#include "JSWorker.h"
#include "JSWritableStream.h"
#include "libusockets.h"
#include "ModuleLoader.h"
#include "napi_external.h"
#include "napi_handle_scope.h"
#include "napi_type_tag.h"
#include "napi.h"
#include "NodeHTTP.h"
#include "NodeVM.h"
#include "Performance.h"
#include "ProcessBindingConstants.h"
#include "ProcessBindingTTYWrap.h"
#include "ReadableStream.h"
#include "SerializedScriptValue.h"
#include "StructuredClone.h"
#include "WebCoreJSBuiltins.h"
#include "ZigSourceProvider.h"
#include "wtf/text/OrdinalNumber.h"
#include "ErrorCode.h"
#include "v8/shim/GlobalInternals.h"
#include "EventLoopTask.h"
#include "NativeEventLoopTarget.h"
#include "NodeModuleModule.h"
#include <JavaScriptCore/JSCBytecodeCacheVersion.h>
#include "JSPerformanceResourceTiming.h"
#include "JSX509Certificate.h"
#include "JSBakeResponse.h"
#include "JSHash.h"
#include "JSDiffieHellman.h"
#include "JSDiffieHellmanGroup.h"
#include "JSCipher.h"
#include "JSKeyObject.h"
#include "JSSecretKeyObject.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"
#include "JSNodePerformanceHooksHistogram.h"
#include "S3Error.h"
#include "ProcessBindingBuffer.h"
#include "NodeValidator.h"
#include "ProcessBindingFs.h"
#include "ProcessBindingHTTPParser.h"
#include "JSConnectionsList.h"
#include "JSHTTPParser.h"
#include <exception>
#include <mutex>
#include "JSBunRequest.h"
#include "ServerRouteList.h"

#if ENABLE(REMOTE_INSPECTOR)
#include "JavaScriptCore/RemoteInspectorServer.h"
#endif

#if !OS(WINDOWS)
#include <dlfcn.h>
#endif

#include <wtf/NumberOfCores.h>

using namespace Bun;

using JSGlobalObject = JSC::JSGlobalObject;
using Exception = JSC::Exception;
using JSValue = JSC::JSValue;
using JSString = JSC::JSString;
using JSModuleLoader = JSC::JSModuleLoader;
using JSModuleRecord = JSC::JSModuleRecord;
using Identifier = JSC::Identifier;
using SourceOrigin = JSC::SourceOrigin;
using JSObject = JSC::JSObject;
using JSNonFinalObject = JSC::JSNonFinalObject;
namespace JSCastingHelpers = JSC::JSCastingHelpers;

#ifndef BUN_WEBKIT_VERSION
#ifndef ASSERT_ENABLED
#warning "BUN_WEBKIT_VERSION is not defined. WebKit's cmakeconfig.h is supposed to define that. If you're building a release build locally, ignore this warning. If you're seeing this warning in CI, please file an issue."
#endif

#define WEBKIT_BYTECODE_CACHE_HASH_KEY __TIMESTAMP__
#else
#define WEBKIT_BYTECODE_CACHE_HASH_KEY BUN_WEBKIT_VERSION
#endif
static consteval unsigned getWebKitBytecodeCacheVersion()
{
    return WTF::SuperFastHash::computeHash(WEBKIT_BYTECODE_CACHE_HASH_KEY);
}
#undef WEBKIT_BYTECODE_CACHE_HASH_KEY

// Declare fuzzilli function registration from FuzzilliREPRL.cpp
#ifdef FUZZILLI_ENABLED
namespace Bun {
void registerFuzzilliFunctions(Zig::GlobalObject*);
}
#endif

std::optional<uint64_t> Bun::Bindgen::Engine::bunBindgenEngine_jsc_initialization_jscInitialize(
    const Bun::Bindgen::Engine::BunBindgenEngine_jsc_initialization_jscInitialize_Arguments& args)
{
    const auto environment = args.environment;
    const auto evalMode = args.evalMode;
    std::optional<uint64_t> invalidEnvironmentOffset;
    static std::once_flag jsc_init_flag;
    // NOLINTBEGIN
    std::call_once(jsc_init_flag, [evalMode, environment, &invalidEnvironmentOffset]() {
        JSC::Config::enableRestrictedOptions();

        std::set_terminate([]() { Bun::Bindgen::ZigExports::bunBindgenZig_CrashHandlerBindings_globalObjectOnCrash(); });
        WTF::initializeMainThread();

#if ASAN_ENABLED && OS(LINUX)
        {
            JSC::Options::AllowUnfinalizedAccessScope scope;

            // ASAN interferes with JSC's signal handlers
            JSC::Options::useWasmFaultSignalHandler() = false;
            JSC::Options::useWasmFastMemory() = false;
        }
#endif

        // Use JSC::initialize with a callback to set Options during initialization.
        // The callback runs BEFORE IPInt::initialize() so we can configure WASM options early.
        JSC::initialize([&] {
            JSC::Options::useWasm() = true;
            JSC::Options::useJIT() = true;
            JSC::Options::useBBQJIT() = true;
            JSC::Options::useConcurrentJIT() = true;
            // JSC::Options::useSigillCrashAnalyzer() = true;
            JSC::Options::useSourceProviderCache() = true;
            // JSC::Options::useUnlinkedCodeBlockJettisoning() = false;
            // JSModuleLoader is now a JSCell (not a JSObject) so exposing it as
            // the global `Loader` would let user code dereference a non-object
            // and trip JSValue::synthesizePrototype's isSymbol() debug assert.
            JSC::Options::exposeInternalModuleLoader() = false;
            JSC::Options::useSharedArrayBuffer() = true;
            JSC::Options::useJITCage() = false;
            JSC::Options::useShadowRealm() = true;
            JSC::Options::useV8DateParser() = true;
            JSC::Options::evalMode() = evalMode;
            JSC::Options::heapGrowthSteepnessFactor() = 1.0;
            JSC::Options::heapGrowthMaxIncrease() = 2.0;
            JSC::Options::useAsyncStackTrace() = true;
            JSC::Options::useExplicitResourceManagement() = true;
            JSC::Options::useTemporal() = true;
            JSC::dangerouslyOverrideJSCBytecodeCacheVersion(getWebKitBytecodeCacheVersion());

#ifdef BUN_DEBUG
            JSC::Options::showPrivateScriptsInStackTraces() = true;
#endif

            static constexpr char prefix[] = "BUN_JSC_";
            static constexpr size_t prefixLength = sizeof(prefix) - 1;
            for (size_t offset = 0; offset < environment.size();) {
                auto remaining = environment.subspan(offset);
                const auto* terminator = static_cast<const uint8_t*>(memchr(remaining.data(), 0, remaining.size()));
                RELEASE_ASSERT(terminator);
                const auto length = static_cast<size_t>(terminator - remaining.data());
                auto entry = remaining.first(length);
                RELEASE_ASSERT(entry.size() >= prefixLength);
                RELEASE_ASSERT(!memcmp(entry.data(), prefix, prefixLength));

                if (!JSC::Options::setOption(reinterpret_cast<const char*>(entry.data() + prefixLength))) [[unlikely]] {
                    invalidEnvironmentOffset = offset;
                    return;
                }
                offset += length + 1;
            }
            JSC::Options::assertOptionsAreCoherent();
        }); // end JSC::initialize lambda
    }); // end std::call_once lambda

    // NOLINTEND
    return invalidEnvironmentOffset;
}

Zig::GlobalObject* ___private___::getDefaultGlobalObject()
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_getDefaultGlobalObject().value_or(nullptr);
}

static void checkIfNextTickWasCalledDuringMicrotask(JSC::VM& vm)
{
    auto* globalObject = defaultGlobalObject();
    if (auto queue = globalObject->m_nextTickQueue.get()) {
        globalObject->resetOnEachMicrotaskTick();
        queue->drain(vm, globalObject);
    }
}

static void cleanupAsyncHooksData(JSC::VM& vm)
{
    auto* globalObject = defaultGlobalObject();
    globalObject->m_asyncContextData.get()->putInternalField(vm, 0, jsUndefined());
    globalObject->asyncHooksNeedsCleanup = false;
    if (!globalObject->m_nextTickQueue) {
        vm.setOnEachMicrotaskTick(&checkIfNextTickWasCalledDuringMicrotask);
        checkIfNextTickWasCalledDuringMicrotask(vm);
    } else {
        vm.setOnEachMicrotaskTick(nullptr);
    }
}

GlobalObject* GlobalObject::create(JSC::VM& vm, JSC::Structure* structure)
{
    GlobalObject* ptr = new (NotNull, JSC::allocateCell<GlobalObject>(vm)) GlobalObject(vm, structure, &globalObjectMethodTable());
    ptr->finishCreation(vm);
    return ptr;
}

GlobalObject* GlobalObject::create(JSC::VM& vm, JSC::Structure* structure, uint32_t scriptExecutionContextId)
{
    GlobalObject* ptr = new (NotNull, JSC::allocateCell<GlobalObject>(vm)) GlobalObject(vm, structure, scriptExecutionContextId, &globalObjectMethodTable());
    ptr->finishCreation(vm);
    return ptr;
}

GlobalObject* GlobalObject::createForTestIsolation(JSC::VM& vm, JSC::Structure* structure, GlobalObject& previous)
{
    auto identifier = WebCore::ScriptExecutionContext::generateIdentifier();
    auto* globalObject = new (NotNull, JSC::allocateCell<GlobalObject>(vm)) GlobalObject(vm, structure, identifier, &globalObjectMethodTable());
    globalObject->scriptExecutionContext()->inheritIdentifierFrom(*previous.scriptExecutionContext());
    globalObject->finishCreation(vm);
    return globalObject;
}

GlobalObject* GlobalObject::create(JSC::VM& vm, JSC::Structure* structure, const JSC::GlobalObjectMethodTable* methodTable)
{
    GlobalObject* ptr = new (NotNull, JSC::allocateCell<GlobalObject>(vm)) GlobalObject(vm, structure, methodTable);
    ptr->finishCreation(vm);
    return ptr;
}

GlobalObject* GlobalObject::create(JSC::VM& vm, JSC::Structure* structure, uint32_t scriptExecutionContextId, const JSC::GlobalObjectMethodTable* methodTable)
{
    GlobalObject* ptr = new (NotNull, JSC::allocateCell<GlobalObject>(vm)) GlobalObject(vm, structure, scriptExecutionContextId, methodTable);
    ptr->finishCreation(vm);
    return ptr;
}

JSC::Structure* GlobalObject::createStructure(JSC::VM& vm)
{
    auto* structure = JSC::Structure::create(vm, nullptr, jsNull(), JSC::TypeInfo(JSC::GlobalObjectType, StructureFlags & ~IsImmutablePrototypeExoticObject), info());
    structure->setTransitionWatchpointIsLikelyToBeFired(true);
    return structure;
}

void Zig::GlobalObject::resetOnEachMicrotaskTick()
{
    auto& vm = this->vm();
    if (this->asyncHooksNeedsCleanup) {
        vm.setOnEachMicrotaskTick(&cleanupAsyncHooksData);
    } else {
        if (this->m_nextTickQueue) {
            vm.setOnEachMicrotaskTick(nullptr);
        } else {
            vm.setOnEachMicrotaskTick(&checkIfNextTickWasCalledDuringMicrotask);
        }
    }
}

// executionContextId: -1 for main thread
// executionContextId: maxInt32 for macros
// executionContextId: >-1 for workers
JSC::JSGlobalObject* Bun::Bindgen::Engine::bunBindgenEngine_global_objects_globalObjectCreate(
    const Bun::Bindgen::Engine::BunBindgenEngine_global_objects_globalObjectCreate_Arguments& args)
{
    int32_t executionContextId = args.context_id;
    bool miniMode = args.mini_mode;
    bool evalMode = args.eval_mode;
    void* worker_ptr = args.worker.value_or(nullptr);
    auto heapSize = miniMode ? JSC::HeapType::Small : JSC::HeapType::Large;
    RefPtr<JSC::VM> vmPtr = JSC::VM::tryCreate(heapSize);
    if (!vmPtr) [[unlikely]] {
        BUN_PANIC("Failed to allocate JavaScriptCore Virtual Machine. Did your computer run out of memory? Or maybe you compiled Bun with a mismatching libc++ version or compiler?");
    }
    vmPtr->refSuppressingSaferCPPChecking();
    JSC::VM& vm = *vmPtr;
    // This must happen before JSVMClientData::create
    vm.heap.acquireAccess();
    JSC::JSLockHolder locker(vm);

    {
        const char* disable_stop_if_necessary_timer = getenv("BUN_DISABLE_STOP_IF_NECESSARY_TIMER");
        // Keep stopIfNecessaryTimer enabled by default when either:
        // - `--smol` is passed
        // - The machine has less than 4GB of RAM
        bool shouldDisableStopIfNecessaryTimer = !miniMode;

        if (disable_stop_if_necessary_timer) {
            const char value = disable_stop_if_necessary_timer[0];
            if (value == '0') {
                shouldDisableStopIfNecessaryTimer = false;
            } else if (value == '1') {
                shouldDisableStopIfNecessaryTimer = true;
            }
        }

        if (shouldDisableStopIfNecessaryTimer) {
            vm.heap.disableStopIfNecessaryTimer();
        }

        // This is used to tell us in the crash reporter how much RSS the system has.
        //
        // JSC already calls this inside JSC::VM::tryCreate and it's cached
        // internally, so there's little cost to calling this multiple times.
        Bun::Bindgen::ZigExports::bunBindgenZig_CrashHandlerBindings_crashHandlerSetMachineMemorySize(WTF::ramSize());
    }

    // Every JS VM's RunLoop should use Bun's RunLoop implementation
    ASSERT(vmPtr->runLoop().kind() == WTF::RunLoop::Kind::Bun);

    WebCore::JSVMClientData::create(&vm, Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_getVirtualMachine());

    const auto createGlobalObject = [&]() -> Zig::GlobalObject* {
        if (executionContextId == std::numeric_limits<int32_t>::max() || executionContextId > 1) [[unlikely]] {
            auto* structure = Zig::GlobalObject::createStructure(vm);
            if (!structure) [[unlikely]] {
                return nullptr;
            }
            return Zig::GlobalObject::create(
                vm,
                structure,
                static_cast<ScriptExecutionContextIdentifier>(executionContextId));
        } else if (evalMode) {
            auto* structure = Zig::EvalGlobalObject::createStructure(vm);
            if (!structure) [[unlikely]] {
                return nullptr;
            }
            return Zig::EvalGlobalObject::create(
                vm,
                structure,
                &Zig::EvalGlobalObject::globalObjectMethodTable());

        } else {
            auto* structure = Zig::GlobalObject::createStructure(vm);
            if (!structure) [[unlikely]] {
                return nullptr;
            }
            return Zig::GlobalObject::create(
                vm,
                structure);
        }
    };

    auto* globalObject = createGlobalObject();
    if (!globalObject) [[unlikely]] {
        BUN_PANIC("Failed to allocate JavaScript global object. Did your computer run out of memory?");
    }

    globalObject->setConsole();
    globalObject->isThreadLocalDefaultGlobalObject = true;
    globalObject->setStackTraceLimit(DEFAULT_ERROR_STACK_TRACE_LIMIT); // Node.js defaults to 10
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_setDefaultGlobalObject(globalObject);
    JSC::gcProtect(globalObject);

#ifdef FUZZILLI_ENABLED
    Bun::registerFuzzilliFunctions(static_cast<Zig::GlobalObject*>(globalObject));
#endif

    vm.setOnComputeErrorInfo(computeErrorInfoWrapperToString);
    vm.setOnComputeErrorInfoJSValue(computeErrorInfoWrapperToJSValue);
    vm.setComputeLineColumnWithSourcemap(computeLineColumnWithSourcemap);
    vm.setOnEachMicrotaskTick([](JSC::VM& vm) -> void {
        // if you process.nextTick on a microtask we need this
        auto* globalObject = defaultGlobalObject();
        if (auto queue = globalObject->m_nextTickQueue.get()) {
            globalObject->resetOnEachMicrotaskTick();
            queue->drain(vm, globalObject);
            return;
        }
    });

    if (executionContextId > -1) {
        const auto initializeWorker = [&](WebCore::Worker& worker) -> void {
            auto& options = worker.options();

            if (options.env.has_value()) {
                HashMap<String, String> map = *std::exchange(options.env, std::nullopt);
                auto size = map.size();

                // In theory, a GC could happen before we finish putting all the properties on the object.
                // So we use a MarkedArgumentBuffer to ensure that the strings are not collected and we immediately put them on the object.
                MarkedArgumentBuffer strings;
                strings.ensureCapacity(size);
                for (const auto& value : map.values()) {
                    strings.append(jsString(vm, value));
                }

                auto env = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), size >= JSFinalObject::maxInlineCapacity ? JSFinalObject::maxInlineCapacity : size);
                size_t i = 0;
                for (auto k : map) {
                    // They can have environment variables with numbers as keys.
                    // So we must use putDirectMayBeIndex to handle that.
                    env->putDirectMayBeIndex(globalObject, JSC::Identifier::fromString(vm, WTF::move(k.key)), strings.at(i++));
                }
                globalObject->m_processEnvObject.set(vm, globalObject, env);
            }

            // Ensure that the TerminationException singleton is constructed. Workers need this so
            // that we can request their termination from another thread. For the main thread, we
            // can delay this until we are actually requesting termination (until and unless we ever
            // do need to request termination from another thread).
            vm.ensureTerminationException();
            // Make the VM stop sooner once terminated (e.g. microtasks won't run)
            vm.forbidExecutionOnTermination();
        };

        if (auto* worker = static_cast<WebCore::Worker*>(worker_ptr)) {
            initializeWorker(*worker);
        }
    }

    return globalObject;
}

// Create a fresh Zig::GlobalObject on the *same* JSC::VM as `oldGlobal`, then unprotect
// the old one so GC can reclaim its module graph. Used by `bun test --isolate` to give
// each test file a clean global without paying for a new JSC::VM.
JSC::JSGlobalObject* Bun::Bindgen::Engine::bunBindgenEngine_global_objects_globalObjectCreateForTestIsolation(
    const Bun::Bindgen::Engine::BunBindgenEngine_global_objects_globalObjectCreateForTestIsolation_Arguments& args)
{
    auto* oldGlobal = uncheckedDowncast<Zig::GlobalObject>(args.old_global);
    JSC::VM& vm = oldGlobal->vm();
    JSC::JSLockHolder locker(vm);

    // `JSGlobalObject::finishCreation` → `init()` performs hundreds of allocations
    // before every lazy/write-barrier member of the Bun subclass has been wired up.
    // Unlike the initial VM global (created before any user code can run and
    // therefore before any concurrent GC is in flight), this one is created while
    // the previous global's graph is live and the heap is warm, so the concurrent
    // marker is far more likely to pick the half-initialized object off the stack
    // and walk it. Deferring GC across the swap keeps the marker from observing the
    // new global (or the mid-swap pair) until both are in a consistent state; the
    // deferred collection fires on scope exit, by which point the new global is
    // gcProtect()'d and the old one is cleanly unprotected.
    JSC::DeferGC deferGC(vm);

    auto* structure = Zig::GlobalObject::createStructure(vm);
    if (!structure) [[unlikely]] {
        BUN_PANIC("Failed to allocate global object structure for test isolation");
    }
    auto* globalObject = Zig::GlobalObject::createForTestIsolation(vm, structure, *oldGlobal);
    if (!globalObject) [[unlikely]] {
        BUN_PANIC("Failed to allocate global object for test isolation");
    }

    globalObject->setConsole();
    globalObject->isThreadLocalDefaultGlobalObject = true;
    globalObject->setStackTraceLimit(DEFAULT_ERROR_STACK_TRACE_LIMIT);
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_setDefaultGlobalObject(globalObject);
    JSC::gcProtect(globalObject);

    // NapiEnv holds a raw Zig::GlobalObject*; deferred napi finalizers for
    // the old global's objects run on the next event-loop tick — after this
    // function returns and the old global is collectable — and would write
    // into the dead cell via NapiHandleScope::open. Point those envs at the
    // new global and adopt the refs before unprotecting the old one.
    globalObject->adoptNapiEnvsForTestIsolation(oldGlobal);

    // Drop the permanent root on the previous global so its module registry,
    // require.cache, and user objects become collectable. JSC's CodeCache and
    // Bun's RuntimeTranspilerCache are VM/process scoped and survive.
    oldGlobal->isThreadLocalDefaultGlobalObject = false;
    JSC::gcUnprotect(oldGlobal);

    return globalObject;
}

static bool isModuleEvaluated(JSC::AbstractModuleRecord* record)
{
    if (!record)
        return false;
    if (auto* cyclic = dynamicDowncast<JSC::CyclicModuleRecord>(record))
        return cyclic->status() == JSC::CyclicModuleRecord::Status::Evaluated && !cyclic->evaluationError();
    // SyntheticModuleRecord is "evaluated" once linked (it has an environment).
    return record->moduleEnvironmentMayBeNull() != nullptr;
}

String GlobalObject::defaultAgentClusterID()
{
    return makeString(WebCore::Process::identifier().toUInt64(), "-default"_s);
}

String GlobalObject::agentClusterID() const
{
    return defaultAgentClusterID();
}

namespace Zig {

using namespace WebCore;

static JSGlobalObject* deriveShadowRealmGlobalObject(JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    // Keep the concurrent marker from walking the new global while finishCreation/init is still populating it.
    JSC::DeferGC deferGC(vm);
    Zig::GlobalObject* shadow = Zig::GlobalObject::create(
        vm,
        Zig::GlobalObject::createStructure(vm),
        ScriptExecutionContext::generateIdentifier());
    shadow->setConsole();

    return shadow;
}

JSC::ScriptExecutionStatus Zig::GlobalObject::scriptExecutionStatus(JSC::JSGlobalObject* globalObject, JSC::JSObject*)
{
    switch (Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineScriptExecutionStatus(
        uncheckedDowncast<Zig::GlobalObject>(globalObject)->bunVM())) {
    case 0:
        return JSC::ScriptExecutionStatus::Running;
    case 1:
        return JSC::ScriptExecutionStatus::Suspended;
    case 2:
        return JSC::ScriptExecutionStatus::Stopped;
    default: {
        RELEASE_ASSERT_NOT_REACHED();
    }
    }
}

void unsafeEvalNoop(JSGlobalObject*, const WTF::String&) {}

void GlobalObject::runNativeMicrotask(JSC::JSGlobalObject* globalObject, void* task)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    Bun::Bindgen::ZigExports::bunBindgenZig_microtasks_runQueuedMicrotask(
        globalObject, static_cast<Bun::NativeMicrotask*>(task));
    RETURN_IF_EXCEPTION(scope, void());
}

void GlobalObject::destroyNativeMicrotask(JSC::JSGlobalObject*, void* task)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_microtasks_discardQueuedMicrotask(
        static_cast<Bun::NativeMicrotask*>(task));
}

const JSC::GlobalObjectMethodTable& GlobalObject::globalObjectMethodTable()
{
    static const JSC::GlobalObjectMethodTable table = {
        &supportsRichSourceInfo,
        &shouldInterruptScript,
        &javaScriptRuntimeFlags,
        nullptr, // &shouldInterruptScriptBeforeTimeout,
        &moduleLoaderImportModule, // moduleLoaderImportModule
        &moduleLoaderResolve, // moduleLoaderResolve
        &moduleLoaderFetch, // moduleLoaderFetch
        &moduleLoaderCreateImportMetaProperties, // moduleLoaderCreateImportMetaProperties
        &moduleLoaderEvaluate, // moduleLoaderEvaluate
        &moduleLoaderAnalyzeTranspiledModule, // moduleLoaderAnalyzeTranspiledModule
        &promiseRejectionTracker, // promiseRejectionTracker
        &reportUncaughtExceptionAtEventLoop,
        &currentScriptExecutionOwner,
        &scriptExecutionStatus,
        &unsafeEvalNoop, // reportViolationForUnsafeEval
        nullptr, // defaultLanguage
        &compileStreaming,
        &instantiateStreaming,
        &Zig::deriveShadowRealmGlobalObject,
        &codeForEval, // codeForEval
        &canCompileStrings, // canCompileStrings
        &trustedScriptStructure, // trustedScriptStructure
        &GlobalObject::runNativeMicrotask,
        &GlobalObject::destroyNativeMicrotask,
    };
    return table;
}

const JSC::GlobalObjectMethodTable& EvalGlobalObject::globalObjectMethodTable()
{
    static const JSC::GlobalObjectMethodTable table = {
        &supportsRichSourceInfo,
        &shouldInterruptScript,
        &javaScriptRuntimeFlags,
        nullptr, // &shouldInterruptScriptBeforeTimeout,
        &moduleLoaderImportModule, // moduleLoaderImportModule
        &moduleLoaderResolve, // moduleLoaderResolve
        &moduleLoaderFetch, // moduleLoaderFetch
        &moduleLoaderCreateImportMetaProperties, // moduleLoaderCreateImportMetaProperties
        &moduleLoaderEvaluate, // moduleLoaderEvaluate
        &moduleLoaderAnalyzeTranspiledModule, // moduleLoaderAnalyzeTranspiledModule
        &promiseRejectionTracker, // promiseRejectionTracker
        &reportUncaughtExceptionAtEventLoop,
        &currentScriptExecutionOwner,
        &scriptExecutionStatus,
        &unsafeEvalNoop, // reportViolationForUnsafeEval
        nullptr, // defaultLanguage
        &compileStreaming,
        &instantiateStreaming,
        &Zig::deriveShadowRealmGlobalObject,
        &codeForEval, // codeForEval
        &canCompileStrings, // canCompileStrings
        &trustedScriptStructure, // trustedScriptStructure
        &GlobalObject::runNativeMicrotask,
        &GlobalObject::destroyNativeMicrotask,
    };
    return table;
}

GlobalObject::GlobalObject(JSC::VM& vm, JSC::Structure* structure, const JSC::GlobalObjectMethodTable* methodTable)
    : Base(vm, structure, methodTable)
    , m_bunVM(Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_getVirtualMachine())
    , m_builtinInternalFunctions(makeUnique<WebCore::JSBuiltinInternalFunctions>(vm))
    , m_scriptExecutionContext(new WebCore::ScriptExecutionContext(&vm, this))
    , globalEventScope(adoptRef(*new Bun::WorkerGlobalScope(m_scriptExecutionContext)))
{
    mockModule = Bun::JSMockModule::create(this);
}

GlobalObject::GlobalObject(JSC::VM& vm, JSC::Structure* structure, WebCore::ScriptExecutionContextIdentifier contextId, const JSC::GlobalObjectMethodTable* methodTable)
    : Base(vm, structure, methodTable)
    , m_bunVM(Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_getVirtualMachine())
    , m_builtinInternalFunctions(makeUnique<WebCore::JSBuiltinInternalFunctions>(vm))
    , m_scriptExecutionContext(new WebCore::ScriptExecutionContext(&vm, this, contextId))
    , globalEventScope(adoptRef(*new Bun::WorkerGlobalScope(m_scriptExecutionContext)))
{
    mockModule = Bun::JSMockModule::create(this);
}

GlobalObject::~GlobalObject()
{
    globalEventScope->detachGlobalObject();
    // Cancel delivery and break the Performance/observer reference cycle while
    // releasing its objects can still unregister context destruction observers.
    if (m_performance)
        m_performance->removeAllObservers();

    if (auto* ctx = scriptExecutionContext()) {
        ctx->removeFromContextsMap();
        ctx->deref();
    }
}

bool GlobalObject::isShuttingDown() const
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineIsShuttingDown(
        reinterpret_cast<VirtualMachine*>(m_bunVM));
}

void GlobalObject::destroy(JSCell* cell)
{
    static_cast<GlobalObject*>(cell)->GlobalObject::~GlobalObject();
}

WebCore::ScriptExecutionContext* GlobalObject::scriptExecutionContext() const
{
    return m_scriptExecutionContext;
}

void GlobalObject::reportUncaughtExceptionAtEventLoop(JSGlobalObject* globalObject,
    JSC::Exception* exception)
{
    if (globalObject->vm().isTerminationException(exception))
        return;
    Bun::Bindgen::ZigExports::bunBindgenZig_errors_reportUnhandledError(globalObject, JSValue(exception));
}

void GlobalObject::promiseRejectionTracker(JSGlobalObject* obj, JSC::JSPromise* promise,
    JSC::JSPromiseRejectionOperation operation)
{
    auto* globalObj = static_cast<GlobalObject*>(obj);

    switch (operation) {
    case JSPromiseRejectionOperation::Reject:
        globalObj->m_aboutToBeNotifiedRejectedPromises.append(obj->vm(), globalObj, promise);
        break;
    case JSPromiseRejectionOperation::Handle:
        bool removed = globalObj->m_aboutToBeNotifiedRejectedPromises.removeFirstMatching(globalObj, [&](JSC::WriteBarrier<JSC::JSPromise>& unhandledPromise) {
            return unhandledPromise.get() == promise;
        });
        if (removed) break;
        // The promise rejection has already been notified, now we need to queue it for the rejectionHandled event
        Bun::Bindgen::ZigExports::bunBindgenZig_promises_handleHandledPromise(globalObj, promise);
        break;
    }
}

void GlobalObject::setConsole()
{
    this->setConsoleClient(new Bun::ConsoleObject());
}

#pragma mark - Globals

WebCore::EventTarget& GlobalObject::eventTarget()
{
    return globalEventScope;
}

}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_createArrayBufferFromBytes(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_createArrayBufferFromBytes_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto arrayBuffer = JSC::ArrayBuffer::tryCreateUninitialized(args.bytes.size(), 1);

    if (!arrayBuffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    if (!args.bytes.empty())
        memcpy(arrayBuffer->data(), args.bytes.data(), args.bytes.size());

    RELEASE_AND_RETURN(scope, JSC::JSArrayBuffer::create(globalObject->vm(), globalObject->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(arrayBuffer)));
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_createUint8ArrayFromBytes(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_createUint8ArrayFromBytes_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* subclassStructure = args.buffer ? static_cast<Zig::GlobalObject*>(globalObject)->JSBufferSubclassStructure() : globalObject->typedArrayStructureWithTypedArrayType<TypeUint8>();
    JSC::JSUint8Array* array = JSC::JSUint8Array::createUninitialized(globalObject, subclassStructure, args.bytes.size());
    RETURN_IF_EXCEPTION(scope, {});

    if (!args.bytes.empty())
        memcpy(array->vector(), args.bytes.data(), args.bytes.size());

    RELEASE_AND_RETURN(scope, array);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_arrayBufferAdoptOwnedBytes(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_arrayBufferAdoptOwnedBytes_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto buffer = Bun::Bindgen::adoptByteOwner(args.owner);
    if (!buffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    JSC::JSArrayBuffer* jsBuffer = JSC::JSArrayBuffer::create(vm, globalObject->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), buffer.releaseNonNull());
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, jsBuffer);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_uint8ArrayAdoptOwnedBytes(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_uint8ArrayAdoptOwnedBytes_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto buffer = Bun::Bindgen::adoptByteOwner(args.owner);
    if (!buffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto length = buffer->byteLength();
    auto* result = JSC::JSUint8Array::create(globalObject, globalObject->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>(), WTF::move(buffer), 0, length);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, result);
}

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_array_buffers_arrayBufferBorrowExternalMemoryUnsafe(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_array_buffers_arrayBufferBorrowExternalMemoryUnsafe_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto buffer = Bun::borrowExternalMemoryUnsafe(args.data, args.length);
    if (!buffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto* result = JSC::JSArrayBuffer::create(vm, globalObject->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), buffer.releaseNonNull());
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, result);
}

namespace Zig {

static WebCore::JSWritableStream* writableStream(const std::optional<JSC::JSValue>& value)
{
    if (!value)
        return nullptr;
    auto* stream = dynamicDowncast<WebCore::JSWritableStream>(*value);
    RELEASE_ASSERT(stream);
    return stream;
}

static WebCore::JSAbortSignal* abortSignal(const std::optional<JSC::JSValue>& value)
{
    if (!value)
        return nullptr;
    auto* signal = dynamicDowncast<WebCore::JSAbortSignal>(*value);
    RELEASE_ASSERT(signal);
    return signal;
}

} // namespace Zig

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_Expect_jestTestModuleObject(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_Expect_jestTestModuleObject_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    return globalObject->internalModuleRegistry()->requireId(globalObject, vm, Bun::InternalModuleRegistry::Field::BunTest);
}

namespace Zig {

#define BUN_BINDGEN_OBJECT_SURFACE_ModuleNamespacePrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ModuleNamespacePrototype

void GlobalObject::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));

    m_commonStrings.initialize();
    m_bakeAdditions.initialize();

    Bun::addNodeModuleConstructorProperties(vm, this);
    m_JSNodeHTTPServerSocketStructure.initLater(
        [](const Initializer<Structure>& init) {
            init.set(Bun::createNodeHTTPServerSocketStructure(init.vm, init.owner));
        });

    m_JSX509CertificateClassStructure.initLater([](LazyClassStructure::Initializer& init) {
        setupX509CertificateClassStructure(init);
    });

    m_JSDiffieHellmanClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            Bun::setupDiffieHellmanClassStructure(init);
        });

    m_JSDiffieHellmanGroupClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            Bun::setupDiffieHellmanGroupClassStructure(init);
        });

    m_JSHashClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupJSHashClassStructure(init);
        });

    m_JSCipherClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupCipherClassStructure(init);
        });

    m_JSKeyObjectClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupKeyObjectClassStructure(init);
        });

    m_JSSecretKeyObjectClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupSecretKeyObjectClassStructure(init);
        });

    m_JSPublicKeyObjectClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupPublicKeyObjectClassStructure(init);
        });

    m_JSPrivateKeyObjectClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupPrivateKeyObjectClassStructure(init);
        });

    m_JSConnectionsListClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupConnectionsListClassStructure(init);
        });

    m_JSHTTPParserClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            setupHTTPParserClassStructure(init);
        });

    m_JSNodePerformanceHooksHistogramClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            Bun::setupJSNodePerformanceHooksHistogramClassStructure(init);
        });

    m_S3ErrorStructure.initLater(
        [](const Initializer<Structure>& init) {
            init.set(Bun::createS3ErrorStructure(init.vm, init.owner));
        });

    m_commonJSModuleObjectStructure.initLater(
        [](const Initializer<Structure>& init) {
            init.set(Bun::createCommonJSModuleStructure(static_cast<Zig::GlobalObject*>(init.owner)));
        });

    m_JSSocketAddressDTOStructure.initLater(
        [](const Initializer<Structure>& init) {
            init.set(Bun::JSSocketAddressDTO::createStructure(init.vm, init.owner));
        });

    m_V8GlobalInternals.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, v8::shim::GlobalInternals>::Initializer& init) {
            init.set(
                v8::shim::GlobalInternals::create(
                    init.vm,
                    v8::shim::GlobalInternals::createStructure(init.vm, init.owner),
                    dynamicDowncast<Zig::GlobalObject>(init.owner)));
        });

    m_errorConstructorPrepareStackTraceInternalValue.initLater(
        [](const Initializer<JSFunction>& init) {
            init.set(JSFunction::create(init.vm, init.owner, 2, "ErrorPrepareStackTrace"_s, bun_bindgen_host_RuntimeFunctions_jsFunctionDefaultErrorPrepareStackTrace, ImplementationVisibility::Public));
        });

    // Change prototype from null to object for synthetic modules.
    m_moduleNamespaceObjectStructure.initLater(
        [](const Initializer<Structure>& init) {
            JSObject* moduleNamespacePrototype = JSC::constructEmptyObject(init.vm, init.owner->nullPrototypeObjectStructure());
            bunBindgenObjectSurface_ModuleNamespacePrototype_install(init.vm, moduleNamespacePrototype->classInfo(), *moduleNamespacePrototype);
            init.set(JSModuleNamespaceObject::createStructure(init.vm, init.owner, moduleNamespacePrototype));
        });

    m_vmModuleContextMap.initLater(
        [](const Initializer<JSWeakMap>& init) {
            init.set(JSWeakMap::create(init.vm, init.owner->weakMapStructure()));
        });

    m_JSBufferSubclassStructure.initLater(
        [](const Initializer<Structure>& init) {
            auto scope = DECLARE_TOP_EXCEPTION_SCOPE(init.vm);
            auto* globalObject = static_cast<Zig::GlobalObject*>(init.owner);
            auto* baseStructure = globalObject->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
            JSC::Structure* subclassStructure = JSC::InternalFunction::createSubclassStructure(globalObject, globalObject->JSBufferConstructor(), baseStructure);
            scope.assertNoExceptionExceptTermination();
            init.set(subclassStructure);
        });
    m_JSResizableOrGrowableSharedBufferSubclassStructure.initLater(
        [](const Initializer<Structure>& init) {
            auto scope = DECLARE_TOP_EXCEPTION_SCOPE(init.vm);
            auto* globalObject = static_cast<Zig::GlobalObject*>(init.owner);
            auto* baseStructure = globalObject->resizableOrGrowableSharedTypedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
            JSC::Structure* subclassStructure = JSC::InternalFunction::createSubclassStructure(globalObject, globalObject->JSBufferConstructor(), baseStructure);
            scope.assertNoExceptionExceptTermination();
            init.set(subclassStructure);
        });
    m_performMicrotaskVariadicFunction.initLater(
        [](const Initializer<JSFunction>& init) {
            init.set(JSFunction::create(init.vm, init.owner, 4, "performMicrotaskVariadic"_s, bun_bindgen_host_GlobalObjectHost_jsFunctionPerformMicrotaskVariadic, ImplementationVisibility::Public));
        });

    m_utilInspectFunction.initLater(
        [](const Initializer<JSFunction>& init) {
            auto scope = DECLARE_THROW_SCOPE(init.vm);
            JSValue nodeUtilValue = uncheckedDowncast<Zig::GlobalObject>(init.owner)->internalModuleRegistry()->requireId(init.owner, init.vm, Bun::InternalModuleRegistry::Field::NodeUtil);
            RETURN_IF_EXCEPTION(scope, );
            RELEASE_ASSERT(nodeUtilValue.isObject());
            auto prop = nodeUtilValue.getObject()->getIfPropertyExists(init.owner, Identifier::fromString(init.vm, "inspect"_s));
            RETURN_IF_EXCEPTION(scope, );
            ASSERT(prop);
            init.set(uncheckedDowncast<JSFunction>(prop));
        });

    m_utilInspectCallCustomFunction.initLater(
        [](const Initializer<JSFunction>& init) {
            auto scope = DECLARE_THROW_SCOPE(init.vm);
            auto function = bun_bindgen_source_function_ConsoleObject_callCustomInspect_value(uncheckedDowncast<Zig::GlobalObject>(init.owner));
            RETURN_IF_EXCEPTION(scope, );
            init.set(uncheckedDowncast<JSFunction>(function));
        });

    m_nodeErrorCache.initLater(
        [](const Initializer<JSObject>& init) {
            auto* structure = ErrorCodeCache::createStructure(
                init.vm,
                init.owner);

            init.set(ErrorCodeCache::create(init.vm, structure));
        });

    m_utilInspectStylizeColorFunction.initLater(
        [](const Initializer<JSFunction>& init) {
            auto scope = DECLARE_THROW_SCOPE(init.vm);
            JSC::MarkedArgumentBuffer args;
            args.append(uncheckedDowncast<Zig::GlobalObject>(init.owner)->utilInspectFunction());
            RETURN_IF_EXCEPTION(scope, );

            JSC::JSFunction* getStylize = JSC::JSFunction::create(init.vm, init.owner, utilInspectGetStylizeWithColorCodeGenerator(init.vm), init.owner);
            RETURN_IF_EXCEPTION(scope, );

            JSC::CallData callData = JSC::getCallData(getStylize);
            auto result = JSC::profiledCall(init.owner, ProfilingReason::API, getStylize, callData, jsNull(), args);
            RETURN_IF_EXCEPTION(scope, );
            init.set(uncheckedDowncast<JSFunction>(result));
        });

    m_utilInspectStylizeNoColorFunction.initLater(
        [](const Initializer<JSFunction>& init) {
            init.set(JSC::JSFunction::create(init.vm, init.owner, utilInspectStylizeWithNoColorCodeGenerator(init.vm), init.owner));
        });

    m_wasmStreamingConsumeStreamFunction.initLater(
        [](const Initializer<JSFunction>& init) {
            init.set(JSC::JSFunction::create(init.vm, init.owner, wasmStreamingConsumeStreamCodeGenerator(init.vm), init.owner));
        });

    m_navigatorObject.initLater(
        [](const Initializer<JSObject>& init) {
            int cpuCount = WTF::numberOfProcessorCores();

            auto str = Bun::Bindgen::ZigExports::bunBindgenZig_runtime_user_agent_runtimeUserAgent();
            JSC::Identifier userAgentIdentifier = JSC::Identifier::fromString(init.vm, "userAgent"_s);
            JSC::Identifier hardwareConcurrencyIdentifier = JSC::Identifier::fromString(init.vm, "hardwareConcurrency"_s);

            JSC::JSObject* obj = JSC::constructEmptyObject(init.owner, init.owner->objectPrototype(), 4);
            obj->putDirect(init.vm, userAgentIdentifier, JSC::jsString(init.vm, str));
            obj->putDirect(init.vm, init.vm.propertyNames->toStringTagSymbol,
                jsNontrivialString(init.vm, "Navigator"_s), PropertyAttribute::DontEnum | PropertyAttribute::ReadOnly);

// https://developer.mozilla.org/en-US/docs/Web/API/Navigator/platform
// https://github.com/oven-sh/bun/issues/4588
#if OS(DARWIN)
            obj->putDirect(init.vm, JSC::Identifier::fromString(init.vm, "platform"_s), JSC::jsString(init.vm, String("MacIntel"_s)));
#elif OS(WINDOWS)
            obj->putDirect(init.vm, JSC::Identifier::fromString(init.vm, "platform"_s), JSC::jsString(init.vm, String("Win32"_s)));
#elif OS(LINUX)
            obj->putDirect(init.vm, JSC::Identifier::fromString(init.vm, "platform"_s), JSC::jsString(init.vm, String("Linux x86_64"_s)));
#endif

            obj->putDirect(init.vm, hardwareConcurrencyIdentifier, JSC::jsNumber(cpuCount));
            init.set(obj);
        });

    m_bunObject.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSObject>::Initializer& init) {
            init.set(Bun::createBunObject(init.vm, init.owner));
        });

    this->initSchemaBindingClasses();

    m_NapiExternalStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(
                Bun::NapiExternal::createStructure(init.vm, init.owner, init.owner->objectPrototype()));
        });

    m_NapiPrototypeStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(
                Bun::NapiPrototype::createStructure(init.vm, init.owner, init.owner->objectPrototype()));
        });

    m_ServerRouteListStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(Bun::createServerRouteListStructure(init.vm, static_cast<Zig::GlobalObject*>(init.owner)));
        });

    m_JSBunRequestParamsPrototype.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSObject>::Initializer& init) {
            init.set(Bun::createJSBunRequestParamsPrototype(init.vm, static_cast<Zig::GlobalObject*>(init.owner)));
        });

    m_JSBunRequestStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(Bun::createJSBunRequestStructure(init.vm, static_cast<Zig::GlobalObject*>(init.owner)));
        });

    m_NapiHandleScopeImplStructure.initLater([](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
        init.set(Bun::NapiHandleScopeImpl::createStructure(init.vm, init.owner));
    });

    m_NapiTypeTagStructure.initLater([](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
        init.set(Bun::NapiTypeTag::createStructure(init.vm, init.owner));
    });

    m_napiTypeTags.initLater([](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSWeakMap>::Initializer& init) {
        init.set(JSC::JSWeakMap::create(init.vm, init.owner->weakMapStructure()));
    });

    m_cachedGlobalProxyStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Structure>::Initializer& init) {
            init.set(
                JSC::JSGlobalProxy::createStructure(init.vm, init.owner, JSC::jsNull()));
        });

    m_NapiClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            init.setStructure(Zig::NapiClass::createStructure(init.vm, init.global, init.global->functionPrototype()));
        });

    m_processEnvObject.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(Bun::createEnvironmentVariablesMap(static_cast<Zig::GlobalObject*>(init.owner)).getObject());
        });

    m_processObject.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Bun::Process>::Initializer& init) {
            auto* globalObject = defaultGlobalObject(init.owner);

            auto* process = Bun::Process::create(
                *globalObject, Bun::Process::createStructure(init.vm, init.owner, globalObject->BunBindgen_WebCoreEvents_EventEmitterPrototype()));

            init.set(process);
        });

    m_lazyReadableStreamPrototypeMap.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSMap>::Initializer& init) {
            auto* map = JSC::JSMap::create(init.vm, init.owner->mapStructure());
            init.set(map);
        });

    m_requireMap.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSMap>::Initializer& init) {
            auto* map = JSC::JSMap::create(init.vm, init.owner->mapStructure());
            init.set(map);
        });

    m_requireFunctionUnbound.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(
                JSFunction::create(
                    init.vm,
                    init.owner,
                    commonJSRequireCodeGenerator(init.vm),
                    init.owner->globalScope(),
                    JSFunction::createStructure(init.vm, init.owner, RequireFunctionPrototype::create(init.owner))));
        });

    m_requireResolveFunctionUnbound.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(
                JSFunction::create(
                    init.vm,
                    init.owner,
                    commonJSRequireResolveCodeGenerator(init.vm),
                    init.owner->globalScope(),
                    JSFunction::createStructure(init.vm, init.owner, RequireResolveFunctionPrototype::create(init.owner))));
        });

    m_internalModuleRegistry.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, Bun::InternalModuleRegistry>::Initializer& init) {
            init.set(
                InternalModuleRegistry::create(
                    init.vm,
                    InternalModuleRegistry::createStructure(init.vm, init.owner)));
        });

    m_processBindingBuffer.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(
                ProcessBindingBuffer::create(
                    init.vm,
                    ProcessBindingBuffer::createStructure(init.vm, init.owner)));
        });

    m_processBindingConstants.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(
                ProcessBindingConstants::create(
                    init.vm,
                    ProcessBindingConstants::createStructure(init.vm, init.owner)));
        });

    m_processBindingFs.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(
                ProcessBindingFs::create(
                    init.vm,
                    ProcessBindingFs::createStructure(init.vm, init.owner)));
        });

    m_processBindingHTTPParser.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
            init.set(
                ProcessBindingHTTPParser::create(
                    init.vm,
                    ProcessBindingHTTPParser::createStructure(init.vm, init.owner)));
        });

    m_importMetaObjectStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            init.set(Zig::ImportMetaObject::createStructure(init.vm, init.owner));
        });

    m_importMetaBakeObjectStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            init.set(Zig::ImportMetaObject::createStructure(init.vm, init.owner, true));
        });

    m_asyncBoundFunctionStructure.initLater(
        [](const JSC::LazyProperty<JSC::JSGlobalObject, JSC::Structure>::Initializer& init) {
            init.set(AsyncContextFrame::createStructure(init.vm, init.owner));
        });

    m_JSBufferClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            auto* prototype = WebCore::createBufferPrototype(init.vm, init.global);
            auto* structure = WebCore::createBufferStructure(init.vm, init.global, JSValue(prototype));
            auto* constructor = WebCore::createBufferConstructor(init.vm, init.global, prototype);
            init.setPrototype(prototype);
            init.setStructure(structure);
            init.setConstructor(constructor);
        });

    m_callSiteStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            auto* prototype = CallSitePrototype::create(init.vm, CallSitePrototype::createStructure(init.vm, init.global, init.global->objectPrototype()), init.global);
            auto* structure = CallSite::createStructure(init.vm, init.global, prototype);
            init.setPrototype(prototype);
            init.setStructure(structure);
        });

    m_JSStringDecoderClassStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            auto* prototype = JSStringDecoderPrototype::create(
                init.vm, init.global, JSStringDecoderPrototype::createStructure(init.vm, init.global, init.global->objectPrototype()));
            auto* structure = JSStringDecoder::createStructure(init.vm, init.global, prototype);
            auto* constructor = JSStringDecoderConstructor::create(
                init.vm, init.global, JSStringDecoderConstructor::createStructure(init.vm, init.global, init.global->functionPrototype()), prototype);
            init.setPrototype(prototype);
            init.setStructure(structure);
            init.setConstructor(constructor);
        });

    m_JSFFIFunctionStructure.initLater(
        [](LazyClassStructure::Initializer& init) {
            init.setStructure(Zig::JSFFIFunction::createStructure(init.vm, init.global, init.global->functionPrototype()));
        });

    m_bunStdin.initLater([](const LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
        init.set(Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_bunStdinCreate(init.owner).getObject());
    });
    m_bunStderr.initLater([](const LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
        init.set(Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_bunStderrCreate(init.owner).getObject());
    });
    m_bunStdout.initLater([](const LazyProperty<JSC::JSGlobalObject, JSC::JSObject>::Initializer& init) {
        init.set(Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_bunStdoutCreate(init.owner).getObject());
    });

    configureNodeVM(vm, this);

#if ENABLE(REMOTE_INSPECTOR)
    setInspectable(false);
#endif

    addBuiltinGlobals(vm);

    ASSERT(classInfo());
}

void GlobalObject::assignStreamToResumableSink(JSValue stream, JSValue sink)
{
    auto& vm = this->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSFunction* function = this->m_assignStreamToResumableSink.get();
    if (!function) {
        function = JSFunction::create(vm, this, static_cast<JSC::FunctionExecutable*>(readableStreamInternalsAssignStreamIntoResumableSinkCodeGenerator(vm)), this);
        this->m_assignStreamToResumableSink.set(vm, this, function);
    }

    auto callData = JSC::getCallData(function);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(stream);
    arguments.append(sink);

    WTF::NakedPtr<JSC::Exception> returnedException = nullptr;

    JSC::profiledCall(this, ProfilingReason::API, function, callData, JSC::jsUndefined(), arguments, returnedException);
    if (auto* exception = returnedException.get()) {
        scope.throwException(this, exception);
    }
}

EncodedJSValue GlobalObject::assignToStream(JSValue stream, JSValue controller)
{
    auto& vm = this->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSFunction* function = this->m_assignToStream.get();
    if (!function) {
        function = JSFunction::create(vm, this, static_cast<JSC::FunctionExecutable*>(readableStreamInternalsAssignToStreamCodeGenerator(vm)), this);
        this->m_assignToStream.set(vm, this, function);
    }

    auto callData = JSC::getCallData(function);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(stream);
    arguments.append(controller);

    WTF::NakedPtr<JSC::Exception> returnedException = nullptr;

    auto result = JSC::profiledCall(this, ProfilingReason::API, function, callData, JSC::jsUndefined(), arguments, returnedException);
    if (auto* exception = returnedException.get()) {
        scope.throwException(this, exception);
        return {};
    }

    return JSC::JSValue::encode(result);
}

JSC::JSObject* GlobalObject::navigatorObject()
{
    return this->m_navigatorObject.get(this);
}

JSC::GCClient::IsoSubspace* GlobalObject::subspaceForImpl(JSC::VM& vm)
{
    return WebCore::subspaceForImpl<GlobalObject, WebCore::UseCustomHeapCellType::Yes>(
        vm,
        [](auto& spaces) { return spaces.m_clientSubspaceForWorkerGlobalScope.get(); },
        [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForWorkerGlobalScope = std::forward<decltype(space)>(space); },
        [](auto& spaces) { return spaces.m_subspaceForWorkerGlobalScope.get(); },
        [](auto& spaces, auto&& space) { spaces.m_subspaceForWorkerGlobalScope = std::forward<decltype(space)>(space); },
        [](auto& server) -> JSC::HeapCellType& { return server.m_heapCellTypeForJSWorkerGlobalScope; });
}

JSValue GlobalObject_getPerformanceObject(VM& vm, JSObject* globalObject)
{
    auto* performance = uncheckedDowncast<Zig::GlobalObject>(globalObject)->performanceObject();
    return performance ? JSValue(performance) : JSValue {};
}

JSValue GlobalObject_getGlobalThis(VM& vm, JSObject* globalObject)
{
    return uncheckedDowncast<Zig::GlobalObject>(globalObject)->globalThis();
}

#define BUN_BINDGEN_OBJECT_SURFACE_ZigGlobalObject
#define BUN_BINDGEN_OBJECT_SURFACE_ErrorConstructorExtensions
#define BUN_BINDGEN_OBJECT_SURFACE_ConsoleObjectExtensions
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ConsoleObjectExtensions
#undef BUN_BINDGEN_OBJECT_SURFACE_ErrorConstructorExtensions
#undef BUN_BINDGEN_OBJECT_SURFACE_ZigGlobalObject

void GlobalObject::addBuiltinGlobals(JSC::VM& vm)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    m_builtinInternalFunctions->initialize(*this);

    bunBindgenObjectSurface_ZigGlobalObject_install(vm, GlobalObject::info(), *this);

    JSC::JSObject* errorConstructor = this->errorConstructor();
    bunBindgenObjectSurface_ErrorConstructorExtensions_install(vm, errorConstructor->classInfo(), *errorConstructor);

    JSC::JSObject* consoleObject = this->get(this, JSC::Identifier::fromString(vm, "console"_s)).getObject();
    scope.assertNoExceptionExceptTermination();
    RETURN_IF_EXCEPTION(scope, );
    bunBindgenObjectSurface_ConsoleObjectExtensions_install(vm, consoleObject->classInfo(), *consoleObject);
}

uint8_t GlobalObject::drainMicrotasks()
{
    auto& vm = this->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (auto* exception = scope.exception()) [[unlikely]] {
        if (vm.isTerminationException(exception)) [[unlikely]] {
            return 1;
        }

#if ASSERT_ENABLED
        (void)scope.tryClearException();
        // We should not have an exception here.
        // But it's an easy mistake to make.
        // Let's log it so that we can debug this.
        reportUncaughtExceptionAtEventLoop(this, exception);

        // And re-throw it to preserve the production behavior.
        auto throwScope = DECLARE_THROW_SCOPE(vm);
        throwScope.throwException(this, exception);
        throwScope.release();
#endif
    }
    scope.assertNoExceptionExceptTermination();

    if (auto nextTickQueue = this->m_nextTickQueue.get()) {
        nextTickQueue->drain(vm, this);
        if (auto* exception = scope.exception()) {
            if (vm.isTerminationException(exception)) {
                return 1;
            }
            (void)scope.tryClearException();
            this->reportUncaughtExceptionAtEventLoop(this, exception);
            return 0;
        }
    }
    vm.drainMicrotasks();
    if (auto* exception = scope.exception()) {
        if (vm.isTerminationException(exception)) {
            return 1;
        }
        (void)scope.tryClearException();
        this->reportUncaughtExceptionAtEventLoop(this, exception);
    }

    return 0;
}

template<class Visitor, class T> static void visitGlobalObjectMember(Visitor& visitor, T& anything)
{
    anything.visit(visitor);
}

template<class Visitor, class T> static void visitGlobalObjectMember(Visitor& visitor, WriteBarrier<T>& barrier)
{
    visitor.append(barrier);
}

template<class Visitor, class T> static void visitGlobalObjectMember(Visitor& visitor, std::unique_ptr<T>& ptr)
{
    // The unique_ptr members are populated in the constructor initializer list,
    // so in steady state this is never null. The concurrent marker can visit a
    // Zig::GlobalObject picked up via conservative stack scan while its own
    // IsoSubspace slot is being recycled from a previously-destroyed global whose
    // unique_ptr members were reset to null by ~unique_ptr(); until placement-new
    // re-initializes them there is a brief window where the pointer reads as null.
    if (ptr) [[likely]]
        ptr->visit(visitor);
}

template<class Visitor, class T, size_t n> static void visitGlobalObjectMember(Visitor& visitor, std::array<WriteBarrier<T>, n>& barriers)
{
    visitor.append(barriers.begin(), barriers.end());
}

template<typename Visitor>
void GlobalObject::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    GlobalObject* thisObject = uncheckedDowncast<GlobalObject>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);

    {
        // The GC thread has to grab the GC lock even though it is not mutating the containers.
        Locker locker { thisObject->m_gcLock };

        for (auto* guarded = thisObject->m_guardedObjects.head(); guarded; guarded = guarded->next())
            guarded->visitAggregate(visitor);
    }

#define VISIT_GLOBALOBJECT_GC_MEMBER(visibility, T, name) \
    visitGlobalObjectMember(visitor, thisObject->name);
    FOR_EACH_GLOBALOBJECT_GC_MEMBER(VISIT_GLOBALOBJECT_GC_MEMBER)
#undef VISIT_GLOBALOBJECT_GC_MEMBER

    WebCore::clientData(thisObject->vm())->httpHeaderIdentifiers().visit<Visitor>(visitor);

    thisObject->visitSchemaBindingClasses<Visitor>(thisObject, visitor);
    thisObject->visitAdditionalChildrenInGCThread<Visitor>(visitor);
}

}

template<typename Arguments>
static void assignStreamIntoResumableSink(
    Bun::Bindgen::EngineCallContext& context,
    const Arguments& args)
{
    static_cast<Zig::GlobalObject&>(context.globalObject).assignStreamToResumableSink(args.stream, context.classValue(args.sink));
}

void Bun::Bindgen::Engine::bunBindgenEngine_resumable_sink_assignStreamIntoFetchSink(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_resumable_sink_assignStreamIntoFetchSink_Arguments& args)
{
    assignStreamIntoResumableSink(context, args);
}

void Bun::Bindgen::Engine::bunBindgenEngine_resumable_sink_assignStreamIntoS3UploadSink(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_resumable_sink_assignStreamIntoS3UploadSink_Arguments& args)
{
    assignStreamIntoResumableSink(context, args);
}

void Bun::Bindgen::Engine::bunBindgenEngine_EventLoop_performTask(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_EventLoop_performTask_Arguments& args)
{
    auto& globalObject = static_cast<Zig::GlobalObject&>(context.globalObject);
    args.task->performTask(*globalObject.scriptExecutionContext());
}

void Bun::Bindgen::Engine::releaseCppTask(WebCore::EventLoopTask* task)
{
    delete task;
}

void Bun::Bindgen::Engine::releaseNativeEventLoopTarget(Bun::NativeEventLoopTarget* target)
{
    target->deref();
}

void Bun::Bindgen::Engine::releaseNativeEventLoopSignal(Bun::NativeEventLoopSignal* signal)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_releaseNativeEventSignal(signal);
}

void Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(Bun::NativeEventLoopSignal* signal)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_closeNativeEventSignal(signal);
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_releaseNativeEventSignal(signal);
}

Bun::NativeEventLoopTarget* Bun::Bindgen::Engine::bunBindgenEngine_EventLoop_retainNativeEventTarget(
    const BunBindgenEngine_EventLoop_retainNativeEventTarget_Arguments& args)
{
    args.target->ref();
    return args.target;
}

void Bun::Bindgen::Engine::bunBindgenEngine_EventLoop_stopNativeEventTarget(
    const BunBindgenEngine_EventLoop_stopNativeEventTarget_Arguments& args)
{
    args.target->stop();
}

void Bun::Bindgen::Engine::bunBindgenEngine_EventLoop_runNativeEventTarget(
    EngineCallContext& context,
    const BunBindgenEngine_EventLoop_runNativeEventTarget_Arguments& args)
{
    args.target->run(&context.globalObject);
}

namespace Zig {

MonotonicTime GlobalObject::performanceTimeOrigin() const
{
    auto nanoseconds = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_readOriginMonotonicNanoseconds(this->bunVM());
    return MonotonicTime::fromRawSeconds(static_cast<double>(nanoseconds) / 1.0e9);
}

RefPtr<Performance> GlobalObject::tryPerformance()
{
    if (!m_performance) {
        auto* context = this->scriptExecutionContext();
        auto wallTimeOriginMilliseconds = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_readOriginTimerStart(this->bunVM());
        m_performance = Performance::tryCreate(context,
            performanceTimeOrigin(),
            WallTime::fromRawSeconds(wallTimeOriginMilliseconds / 1000.0));
    }

    return m_performance;
}

JSC::JSObject* GlobalObject::performanceObject()
{
    if (auto* cached = m_performanceObject.get())
        return cached;
    auto scope = DECLARE_THROW_SCOPE(vm());
    auto performance = tryPerformance();
    if (!performance) {
        throwOutOfMemoryError(this, scope);
        return nullptr;
    }
    auto value = toJS(this, this, performance.get());
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* object = asObject(value);
    m_performanceObject.set(vm(), this, object);
    return object;
}

void GlobalObject::queueTask(WebCore::EventLoopTask* task)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_queueTask(this, task);
}

void GlobalObject::queueTaskConcurrently(WebCore::EventLoopTask* task)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_queueTaskConcurrently(this, task);
}

void GlobalObject::handleRejectedPromises()
{
    JSC::VM& virtual_machine = vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(virtual_machine);
    while (auto* promise = m_aboutToBeNotifiedRejectedPromises.takeFirst(this)) {
        if (promise->isHandled())
            continue;

        Bun::Bindgen::ZigExports::bunBindgenZig_promises_handleRejectedPromise(this, promise);
        if (auto* exception = scope.exception()) {
            if (!scope.clearExceptionExceptTermination())
                return;
            this->reportUncaughtExceptionAtEventLoop(this, exception);
            if (scope.exception())
                return;
        }
    }
}

DEFINE_VISIT_CHILDREN(GlobalObject);

template<typename Visitor>
void GlobalObject::visitAdditionalChildrenInGCThread(Visitor& visitor)
{
    GlobalObject* thisObject = this;
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());

    thisObject->globalEventScope->visitJSEventListeners(visitor);

    thisObject->m_aboutToBeNotifiedRejectedPromises.visit(thisObject, visitor);

    ScriptExecutionContext* context = thisObject->scriptExecutionContext();
    visitor.addOpaqueRoot(context);
}

DEFINE_VISIT_ADDITIONAL_CHILDREN_IN_GC_THREAD(GlobalObject);

template<typename Visitor>
void GlobalObject::visitOutputConstraints(JSCell* cell, Visitor& visitor)
{
    auto* thisObject = uncheckedDowncast<GlobalObject>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitOutputConstraints(thisObject, visitor);
    thisObject->visitAdditionalChildrenInGCThread(visitor);
}

template void GlobalObject::visitOutputConstraints(JSCell*, AbstractSlotVisitor&);
template void GlobalObject::visitOutputConstraints(JSCell*, SlotVisitor&);

void GlobalObject::reload()
{
    auto& vm = this->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    this->moduleLoader()->clearAll();
    this->requireMap()->clear(this);
    RETURN_IF_EXCEPTION(scope, );

    // If we run the GC every time, we will never get the SourceProvider cache hit.
    // So we run the GC every other time.
    if ((this->reloadCount++ + 1) % 2 == 0) {
        this->vm().heap.collectSync();
    }
}

JSC::Identifier GlobalObject::moduleLoaderResolve(JSGlobalObject* jsGlobalObject,
    JSModuleLoader* loader, JSValue key,
    JSValue referrer, RefPtr<JSC::ScriptFetcher>, bool)
{
    Zig::GlobalObject* globalObject = static_cast<Zig::GlobalObject*>(jsGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    WTF::String keyString;
    if (key.isString()) {
        WTF::String moduleName = uncheckedDowncast<JSString>(key)->value(globalObject);
        RETURN_IF_EXCEPTION(scope, globalObject->vm().propertyNames->emptyIdentifier);
        if (moduleName.startsWith("file://"_s)) {
            auto url = WTF::URL(moduleName);
            if (url.isValid() && !url.isEmpty()) {
                keyString = url.fileSystemPath();
            } else {
                keyString = moduleName;
            }
        } else {
            keyString = moduleName;
        }

    } else {
        keyString = key.toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, globalObject->vm().propertyNames->emptyIdentifier);
    }
    WTF::String referrerString = referrer && !referrer.isUndefinedOrNull() && referrer.isString() ? referrer.toWTFString(globalObject) : WTF::String();
    RETURN_IF_EXCEPTION(scope, globalObject->vm().propertyNames->emptyIdentifier);

    if (globalObject->onLoadPlugins.hasVirtualModules()) {
        if (auto resolvedString = globalObject->onLoadPlugins.resolveVirtualModule(keyString, referrerString)) {
            return Identifier::fromString(globalObject->vm(), resolvedString.value());
        }
    } else {
        ASSERT(!globalObject->onLoadPlugins.mustDoExpensiveRelativeLookup);
    }

    // The new C++ loader calls resolve() on keys that moduleLoaderImportModule
    // already resolved through plugin onResolve. If the key already carries a
    // plugin namespace that has an onLoad handler, it is a fully-resolved
    // virtual key — return it unchanged so we don't fall through to the
    // filesystem resolver and fail with "Cannot find module".
    //
    // FIXME(module-loader): this short-circuit ignores the plugin's filter
    // and bypasses any onResolve handler for static imports written directly
    // as "ns:..." in source. The proper fix is for moduleLoaderImportModule
    // to mark keys it already resolved so we can skip only those.
    if (!globalObject->onLoadPlugins.namespaces.isEmpty()) {
        if (auto colon = keyString.find(':'); colon != WTF::notFound && !(colon == 1 && isASCIIAlpha(keyString[0]))) {
            // colon == 1 with a leading ASCII letter is a Windows drive
            // ("C:\\..."), never a plugin namespace.
            auto ns = keyString.left(colon);
            for (const auto& registered : globalObject->onLoadPlugins.namespaces) {
                if (registered == ns) {
                    return Identifier::fromString(globalObject->vm(), keyString);
                }
            }
        }
    }

    auto resolved = Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_moduleLoaderResolve(globalObject, keyString, referrerString);
    RETURN_IF_EXCEPTION(scope, globalObject->vm().propertyNames->emptyIdentifier);
    return Identifier::fromString(globalObject->vm(), resolved);
}

JSC::JSPromise* GlobalObject::moduleLoaderImportModule(JSGlobalObject* jsGlobalObject,
    JSModuleLoader* moduleLoader,
    JSString* moduleNameValue,
    RefPtr<JSC::ScriptFetchParameters> parameters,
    const SourceOrigin& sourceOrigin,
    bool deferred)
{
    UNUSED_PARAM(deferred);
    auto* globalObject = static_cast<Zig::GlobalObject*>(jsGlobalObject);

    VM& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    {
        JSC::JSPromise* result = NodeVM::importModule(globalObject, moduleNameValue, parameters, sourceOrigin);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (result) {
            return result;
        }
    }

    JSC::Identifier resolvedIdentifier;

    WTF::String moduleName = moduleNameValue->value(globalObject);
    RETURN_IF_EXCEPTION(scope, nullptr);

    auto sourceURL = sourceOrigin.url();
    String sourceOriginStringHolder;
    int64_t referrerAsyncOrder = -1;
    if (sourceURL.isEmpty()) {
        sourceOriginStringHolder = "."_s;
    } else if (sourceURL.protocolIsFile()) {
        sourceOriginStringHolder = sourceURL.fileSystemPath();
        auto query = sourceURL.queryWithLeadingQuestionMark();
        auto referrerKey = query.isEmpty()
            ? JSC::Identifier::fromString(vm, sourceOriginStringHolder)
            : JSC::Identifier::fromString(vm, makeString(sourceOriginStringHolder, query));
        referrerAsyncOrder = moduleLoader->asyncEvaluationOrderForKey(referrerKey);
    } else if (sourceURL.protocol() == "builtin"_s) {
        ASSERT(sourceURL.string().startsWith("builtin://"_s));
        sourceOriginStringHolder = sourceURL.string().substringSharingImpl(10);
    } else {
        sourceOriginStringHolder = sourceURL.path().toString();
    }

    if (globalObject->onLoadPlugins.hasVirtualModules()) {
        if (auto resolution = globalObject->onLoadPlugins.resolveVirtualModule(moduleName, sourceURL.protocolIsFile() ? sourceOriginStringHolder : String())) {
            resolvedIdentifier = JSC::Identifier::fromString(vm, resolution.value());

            auto result = JSC::importModule(globalObject, resolvedIdentifier, JSC::Identifier(), parameters, nullptr, /* deferred */ false, referrerAsyncOrder);
            if (scope.exception()) [[unlikely]] {
                return JSC::JSPromise::rejectedPromiseWithCaughtException(globalObject, scope);
            }
            return result;
        }
    }

    {
        String moduleStringHolder;
        if (moduleName.startsWith("file://"_s)) {
            auto url = WTF::URL(moduleName);
            if (url.isValid() && !url.isEmpty()) {
                moduleStringHolder = url.fileSystemPath();
            } else {
                moduleStringHolder = moduleName;
            }
        } else {
            moduleStringHolder = moduleName;
        }

        auto resolved = Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_moduleLoaderResolve(globalObject, moduleStringHolder, sourceOriginStringHolder);

        if (scope.exception()) [[unlikely]] {
            return JSC::JSPromise::rejectedPromiseWithCaughtException(globalObject, scope);
        }

        resolvedIdentifier = JSC::Identifier::fromString(vm, resolved);
    }

    auto result = JSC::importModule(globalObject, resolvedIdentifier,
        JSC::Identifier(), WTF::move(parameters), nullptr, /* deferred */ false, referrerAsyncOrder);
    if (scope.exception()) [[unlikely]] {
        return JSC::JSPromise::rejectedPromiseWithCaughtException(globalObject, scope);
    }

    ASSERT(result);
    return result;
}

static JSC::JSPromise* rejectedInternalPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto& vm = JSC::getVM(globalObject);
    JSPromise* promise = JSPromise::create(vm, globalObject->promiseStructure());
    promise->rejectAsHandled(vm, value);
    return promise;
}

static JSC::JSPromise* resolvedInternalPromise(JSC::JSGlobalObject* globalObject, JSC::JSValue value)
{
    auto& vm = JSC::getVM(globalObject);
    JSPromise* promise = JSPromise::create(vm, globalObject->promiseStructure());
    promise->fulfill(vm, value);
    return promise;
}

JSC::JSPromise* GlobalObject::moduleLoaderFetch(JSGlobalObject* globalObject,
    JSModuleLoader* loader, JSValue key,
    RefPtr<JSC::ScriptFetchParameters> parameters, RefPtr<JSC::ScriptFetcher>)
{
    auto& vm = JSC::getVM(globalObject);

    auto scope = DECLARE_THROW_SCOPE(vm);

    auto moduleKeyJS = key.toString(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    // Fetching can pump the event loop through async macros, so retain the key beyond the GC-owned borrow.
    WTF::String moduleKey = moduleKeyJS->value(globalObject);
    if (scope.exception()) [[unlikely]]
        return rejectedInternalPromise(globalObject, scope.exception()->value());

    const WTF::String referrer = "undefined"_s;
    std::optional<WTF::String> typeAttribute;

    if (parameters) {
        if (parameters->type() == ScriptFetchParameters::Type::HostDefined) {
            typeAttribute = parameters->hostDefinedImportType();
        } else if (parameters->type() == ScriptFetchParameters::Type::JSON) {
            typeAttribute = "json"_s;
        } else if (parameters->type() == ScriptFetchParameters::Type::WebAssembly) {
            typeAttribute = "webassembly"_s;
        }
    }

    ResolvedSourceResult res {};

    // require(esm) needs the entire dependency graph to load without yielding
    // to microtasks. The async fetch path goes through Zig's transpiler thread
    // pool; route to the synchronous fetch instead so the returned promise is
    // already fulfilled and the loader keeps draining its private queue (see
    // JSModuleLoader::loadModuleSync / VM::m_synchronousModuleQueue).
    if (vm.m_synchronousModuleQueue) {
        JSValue result = Bun::fetchESMSourceCodeSync(
            static_cast<Zig::GlobalObject*>(globalObject),
            moduleKeyJS,
            res,
            moduleKey,
            referrer,
            typeAttribute);
        RETURN_IF_EXCEPTION(scope, rejectedInternalPromise(globalObject, scope.exception()->value()));
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(result))
            return promise;
        if (result && result.inherits<JSC::JSSourceCode>())
            return resolvedInternalPromise(globalObject, result);
        return rejectedInternalPromise(globalObject, result ? result : JSC::jsUndefined());
    }

    JSValue result = Bun::fetchESMSourceCodeAsync(
        static_cast<Zig::GlobalObject*>(globalObject),
        moduleKeyJS,
        res,
        moduleKey,
        referrer,
        typeAttribute);

    RETURN_IF_EXCEPTION(scope, rejectedInternalPromise(globalObject, scope.exception()->value()));
    ASSERT(result);
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
        return promise;
    }
    return rejectedInternalPromise(globalObject, result);
}

JSC::JSObject* GlobalObject::moduleLoaderCreateImportMetaProperties(JSGlobalObject* globalObject,
    JSModuleLoader* loader,
    JSValue key,
    JSModuleRecord* record,
    RefPtr<JSC::ScriptFetcher>)
{
    return Zig::ImportMetaObject::create(globalObject, key);
}

JSC::JSValue GlobalObject::moduleLoaderEvaluate(JSGlobalObject* lexicalGlobalObject,
    JSModuleLoader* moduleLoader, JSValue key,
    JSValue moduleRecordValue, RefPtr<JSC::ScriptFetcher> scriptFetcher,
    JSValue sentValue, JSValue resumeMode)
{
    return moduleLoader->evaluateNonVirtual(lexicalGlobalObject, key, moduleRecordValue,
        WTF::move(scriptFetcher), sentValue, resumeMode);
}

JSC::JSValue EvalGlobalObject::moduleLoaderEvaluate(JSGlobalObject* lexicalGlobalObject,
    JSModuleLoader* moduleLoader, JSValue key,
    JSValue moduleRecordValue, RefPtr<JSC::ScriptFetcher> scriptFetcher,
    JSValue sentValue, JSValue resumeMode)
{
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSC::JSValue result = moduleLoader->evaluateNonVirtual(lexicalGlobalObject, key, moduleRecordValue,
        WTF::move(scriptFetcher), sentValue, resumeMode);
    RETURN_IF_EXCEPTION(scope, result);

    bool isEvalEntryPoint = Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_specifierIsEvalEntryPoint(globalObject, key);
    RETURN_IF_EXCEPTION(scope, result);
    if (isEvalEntryPoint) {
        // For a module with top-level `await`, JSC compiles the body as a
        // generator and the first call into evaluate() yields the awaited
        // value — NOT the module's final completion value. If we captured
        // that yielded value here, `bun -p '(await 1) + 1'` would print `1`
        // instead of `2`. The resume path (asyncModuleExecutionResume in
        // WebKit) calls module->evaluate() directly and bypasses this hook,
        // so we can't rely on a later call to overwrite the captured value.
        //
        // Instead, when the module yielded, capture the async capability's
        // promise. Its resolution value is the module's final completion
        // value; the --print loop in bun.js.zig already unwraps promises
        // before the generated entry-point resolve callback.
        JSC::JSValue valueToStore = result;
        if (auto* moduleRecord = dynamicDowncast<JSC::AbstractModuleRecord>(moduleRecordValue)) {
            JSC::JSValue state = moduleRecord->internalField(JSC::AbstractModuleRecord::Field::State).get();
            bool moduleYielded = state.isNumber() && state.asNumber() != static_cast<int32_t>(JSC::JSGenerator::State::Executing);
            if (moduleYielded) {
                if (auto* capability = moduleRecord->asyncCapability())
                    valueToStore = capability;
            }
        }
        Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_setEntryPointEvalResultESM(globalObject, valueToStore);
        RETURN_IF_EXCEPTION(scope, {});
    }

    return result;
}

} // namespace Zig

void Bun::Bindgen::Engine::bunBindgenEngine_WasmStreamingEngine_wasmStreamingCompilerAddBytes(
    const Bun::Bindgen::Engine::BunBindgenEngine_WasmStreamingEngine_wasmStreamingCompilerAddBytes_Arguments& args)
{
    args.compiler->addBytes(args.bytes);
}

namespace Zig {

static void handleResponseOnStreamingAction(JSGlobalObject* lexicalGlobalObject, JSC::JSPromise* promise, JSC::JSValue source, JSC::Wasm::CompilerMode mode, JSC::JSObject* importObject, std::optional<JSC::WebAssemblyCompileOptions>&& compileOptions)
{
    auto globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSLockHolder locker(vm);

    auto sourceCode = makeSource("[wasm code]"_s, SourceOrigin(), SourceTaintedOrigin::Untainted);
    auto compiler = JSC::Wasm::StreamingCompiler::create(vm, mode, globalObject, promise, importObject, WTF::move(compileOptions), sourceCode);

    auto readableStreamMaybe = Bun::Bindgen::ZigExports::bunBindgenZig_WasmStreamingEngine_getBodyStreamOrBytesForWasmStreaming(
        globalObject, source, compiler.ptr());

    if (scope.exception()) [[unlikely]] {
        promise->rejectWithCaughtException(vm, scope);
        return;
    }

    // We were able to get the slice synchronously.
    if (!readableStreamMaybe) {
        compiler->finalize(globalObject);

        if (scope.exception()) [[unlikely]]
            promise->rejectWithCaughtException(vm, scope);
        return;
    }

    auto wrapper = JSC::Wasm::toJSNewlyCreated(globalObject, globalObject, WTF::move(compiler));
    auto builtin = globalObject->wasmStreamingConsumeStreamFunction();
    auto callData = JSC::getCallData(builtin);
    MarkedArgumentBuffer arguments;

    arguments.append(*readableStreamMaybe);
    JSC::call(globalObject, builtin, callData, wrapper, arguments);
    if (scope.exception()) [[unlikely]]
        promise->rejectWithCaughtException(vm, scope);
}

void GlobalObject::compileStreaming(JSGlobalObject* globalObject, JSC::JSPromise* promise, JSC::JSValue source, std::optional<JSC::WebAssemblyCompileOptions>&& compileOptions)
{
    handleResponseOnStreamingAction(globalObject, promise, source, JSC::Wasm::CompilerMode::Validation, nullptr, WTF::move(compileOptions));
}

void GlobalObject::instantiateStreaming(JSGlobalObject* globalObject, JSC::JSPromise* promise, JSC::JSValue source, JSC::JSObject* importObject, std::optional<JSC::WebAssemblyCompileOptions>&& compileOptions)
{
    handleResponseOnStreamingAction(globalObject, promise, source, JSC::Wasm::CompilerMode::FullCompile, importObject, WTF::move(compileOptions));
}

GlobalObject::PromiseFunctions GlobalObject::promiseHandlerID(JSC::NativeFunction handler)
{
#define BUN_BINDGEN_PROMISE_REACTION_HANDLER(symbol) if (handler == symbol) return GlobalObject::PromiseFunctions::symbol;
#include "SchemaBindingsPromiseReactionHandlers.inc"
#undef BUN_BINDGEN_PROMISE_REACTION_HANDLER
    RELEASE_ASSERT_NOT_REACHED();
}

Ref<NapiEnv> GlobalObject::makeNapiEnv(const napi_module& mod)
{
    m_napiEnvs.append(NapiEnv::create(this, mod));
    return m_napiEnvs.last();
}

napi_env GlobalObject::makeNapiEnvForFFI()
{
    auto out = makeNapiEnv(napi_module {
        .nm_version = 9,
        .nm_flags = 0,
        .nm_filename = "ffi://",
        .nm_register_func = nullptr,
        .nm_modname = "[ffi]",
        .nm_priv = nullptr,
        .reserved = {},
    });
    return &out.leakRef();
}

bool GlobalObject::hasNapiFinalizers() const
{
    for (const auto& env : m_napiEnvs) {
        if (env->hasFinalizers()) {
            return true;
        }
    }

    return false;
}

// `bun test --isolate`: the old global is about to be gcUnprotect()'d and
// collected, but its NapiEnvs may outlive it — GC-enqueued NapiFinalizerTasks
// hold Ref<NapiEnv> and run on the event loop while loading the *next* file.
// NapiEnv::m_globalObject is a raw pointer; Finalizer.run opens a
// NapiHandleScope through it, which writes m_currentNapiHandleScopeImpl on the
// dead old global and trips `ASSERT(isMarked(cell))` in
// Heap::addToRememberedSet (release: the concurrent marker later visits it and
// segfaults at offset 0x68/0xD0). Retarget every env to the new global and
// take ownership of the refs so ~GlobalObject on the old one doesn't drop
// them — the envs stay valid for late finalizers and for the process-exit
// cleanup hooks in rare_data.cleanup_hooks (which hold raw NapiEnv* in .ctx).
void GlobalObject::adoptNapiEnvsForTestIsolation(GlobalObject* oldGlobal)
{
    if (oldGlobal->m_napiEnvs.isEmpty())
        return;
    for (auto& env : oldGlobal->m_napiEnvs)
        env->retargetGlobalObject(this);
    // Ref<NapiEnv> is move-only; the rvalue appendVector overload moves each
    // element out, and we make the source explicitly empty afterwards so
    // ~GlobalObject on the old cell is a no-op here.
    m_napiEnvs.appendVector(std::exchange(oldGlobal->m_napiEnvs, {}));
}

void GlobalObject::setNodeWorkerEnvironmentData(JSMap* data) { m_nodeWorkerEnvironmentData.set(vm(), this, data); }

static bool destructGlobalObjectOnExit(Zig::GlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    if (vm.entryScope) {
        // An active JavaScript entry still borrows the engine and native VM state.
        return false;
    }
    JSC::JSLockHolder lock(vm);
    void* bunVM = globalObject->bunVM();
    gcUnprotect(globalObject);
    globalObject = nullptr;
    vm.heap.collectNow(JSC::Sync, JSC::CollectionScope::Full);
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineDrainNativeFinalizers(
        reinterpret_cast<VirtualMachine*>(bunVM));
    vm.derefSuppressingSaferCPPChecking();
    return vm.hasOneRef();
}

#include "SchemaBindings+lazyStructureImpl.h"

const JSC::ClassInfo GlobalObject::s_info = { "GlobalObject"_s, &Base::s_info, &bunBindgenObjectSurface_ZigGlobalObjectTable, nullptr,
    CREATE_METHOD_TABLE(GlobalObject) };

} // namespace Zig

#if OS(WINDOWS)
uv_loop_t* Zig::GlobalObject::uvLoop() const
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineUVLoop(const_cast<GlobalObject*>(this));
}
#endif

bool Bun::Bindgen::Engine::bunBindgenEngine_global_objects_globalObjectDestructOnExit(
    const Bun::Bindgen::Engine::BunBindgenEngine_global_objects_globalObjectDestructOnExit_Arguments& args)
{
    return Zig::destructGlobalObjectOnExit(args.globalObject);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionCheckBufferRead(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionCheckBufferRead_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());

    const auto* buffer = args.buffer.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!buffer)
        return;

    const auto* byteLength = args.byteLength.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!byteLength)
        return;
    auto* view = uncheckedDowncast<JSC::JSArrayBufferView>(*buffer);
    const size_t bufferLength = view->isDetached() ? 0 : view->byteLength();
    if (*byteLength > bufferLength) {
        (void)Bun::ERR::BUFFER_OUT_OF_BOUNDS(scope, globalObject, ""_s);
        return;
    }

    const auto maximumOffset = static_cast<int64_t>(bufferLength - *byteLength);
    if (args.offset < 0 || args.offset > maximumOffset) {
        auto range = WTF::tryMakeString(">= 0 and <= "_s, maximumOffset);
        if (range.isNull()) {
            throwOutOfMemoryError(globalObject, scope);
            return;
        }
        (void)Bun::ERR::OUT_OF_RANGE(
            scope,
            globalObject,
            "offset"_s,
            range,
            JSC::jsNumber(args.offset));
    }
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionFulfillModuleSync(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionFulfillModuleSync_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    const WTF::String& moduleKey = args.moduleKey;
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);

    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    ResolvedSourceResult res {};
    auto* moduleKeyString = JSC::jsString(vm, moduleKey);

    JSValue result = Bun::fetchESMSourceCodeSync(
        globalObject,
        moduleKeyString,
        res,
        moduleKey,
        moduleKey,
        std::nullopt);

    if (scope.exception() || !result) {
        scope.release();
        return;
    }

    globalObject->moduleLoader()->provideFetch(globalObject, JSC::Identifier::fromString(vm, moduleKey), JSC::ScriptFetchParameters::Type::JavaScript, uncheckedDowncast<JSC::JSSourceCode>(result));
    scope.release();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionEsmLoadSync(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionEsmLoadSync_Arguments& args)
{
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    const WTF::String& keyString = args.key;
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto key = JSC::Identifier::fromString(vm, keyString);

    auto* loader = globalObject->moduleLoader();
    bool entryExistedBefore = false;
    if (auto* entry = loader->registryEntry(key)) {
        entryExistedBefore = true;
        if (isModuleEvaluated(entry->record())) {
            auto* ns = entry->record()->getModuleNamespace(globalObject, false);
            RETURN_IF_EXCEPTION(scope, {});
            return ns;
        }
    }

    JSPromise* promise = loader->loadModuleSync(globalObject, key, nullptr, nullptr);
    RETURN_IF_EXCEPTION(scope, {});

    switch (promise->status()) {
    case JSPromise::Status::Fulfilled:
        break;
    case JSPromise::Status::Rejected: {
        promise->markAsHandled();
        JSValue error = promise->result();
        scope.throwException(globalObject, error);
        return {};
    }
    case JSPromise::Status::Pending: {
        promise->markAsHandled();
        // The load promise stays Pending when this module shares an SCC with an
        // outer module that is still Evaluating (e.g. ESM entry → CJS shim →
        // require(esm) → imports something the entry already loaded). For a
        // non-TLA record whose status is exactly Evaluating, the body already
        // ran synchronously; only the status flip waits on the SCC root. Treat
        // that as success — the namespace is fully populated.
        //
        // Explicitly exclude EvaluatingAsync: a record reaches that state when
        // it OR any dependency has top-level await, in which case bindings can
        // still be in TDZ and we must throw the "async module" error instead
        // of returning a half-initialized namespace.
        if (auto* entry = loader->registryEntry(key)) {
            if (auto* cyclic = dynamicDowncast<JSC::CyclicModuleRecord>(entry->record())) {
                auto status = cyclic->status();
                if ((status == JSC::CyclicModuleRecord::Status::Evaluating || status == JSC::CyclicModuleRecord::Status::Evaluated) && !cyclic->hasTLA() && !cyclic->evaluationError())
                    break;
            }
        }
        // Only drop the entry we created. If the entry already existed (an
        // outer import() is mid-load, or the module is EvaluatingAsync from a
        // prior import), removing it would force a second evaluation and a
        // second namespace object once that outer load completes.
        if (!entryExistedBefore)
            loader->removeEntry(key);
        {
            throwVMTypeError(globalObject, scope, makeString("require() async module \""_s, keyString, "\" is unsupported. use \"await import()\" instead."_s));
            return {};
        }
    }
    }

    auto* entry = loader->registryEntry(key);
    if (!entry || !entry->record()) [[unlikely]] {
        throwVMTypeError(globalObject, scope, makeString("require() failed to evaluate module \""_s, keyString, "\". This is an internal consistentency error."_s));
        return {};
    }

    // The loadModule promise resolved, so the entire graph linked + evaluated
    // synchronously. We deliberately do NOT gate on CyclicModuleRecord::status()
    // here: when require(esm) is called from inside an outer ESM graph that is
    // itself mid-evaluation (a CJS shim imported by an ESM entry), the inner
    // record's body has already run but its status only flips to Evaluated once
    // the SCC root (the outer module we're currently inside) settles. Returning
    // the namespace in that state matches the old loader's behaviour and Node's
    // require(esm) cycle semantics. evaluationError() still surfaces a real
    // throw from the module body.
    auto* record = entry->record();
    if (auto* cyclic = dynamicDowncast<JSC::CyclicModuleRecord>(record)) {
        if (JSValue err = cyclic->evaluationError()) {
            scope.throwException(globalObject, err);
            return {};
        }
    }

    auto* ns = record->getModuleNamespace(globalObject, false);
    RETURN_IF_EXCEPTION(scope, {});
    return ns;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionCreateUninitializedArrayBuffer(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionCreateUninitializedArrayBuffer_Arguments& args)
{
    size_t length;
    switch (args.length.tag()) {
    case Bun::Bindgen::UninitializedArrayBufferLength::Tag::number:
        length = args.length.number();
        break;
    case Bun::Bindgen::UninitializedArrayBufferLength::Tag::bigint:
        length = args.length.bigint();
        break;
    case Bun::Bindgen::UninitializedArrayBufferLength::Tag::none:
        RELEASE_ASSERT_NOT_REACHED();
    }
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto arrayBuffer = JSC::ArrayBuffer::tryCreateUninitialized(length, 1);

    if (!arrayBuffer) [[unlikely]] {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    RELEASE_AND_RETURN(scope, JSC::JSArrayBuffer::create(globalObject->vm(), globalObject->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(arrayBuffer)));
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionEsmNamespaceForCjs(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionEsmNamespaceForCjs_Arguments& args)
{
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const std::optional<WTF::String>& keyString = args.key;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!keyString)
        return std::nullopt;
    auto key = JSC::Identifier::fromString(vm, *keyString);
    RETURN_IF_EXCEPTION(scope, {});
    auto* entry = globalObject->moduleLoader()->registryEntry(key);
    if (!entry || !isModuleEvaluated(entry->record()))
        return std::nullopt;
    auto* ns = entry->record()->getModuleNamespace(globalObject, false);
    RETURN_IF_EXCEPTION(scope, {});
    return ns;
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionEsmRegistryDelete(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionEsmRegistryDelete_Arguments& args)
{
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const std::optional<WTF::String>& keyString = args.key;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!keyString)
        return false;
    auto key = JSC::Identifier::fromString(vm, *keyString);
    RETURN_IF_EXCEPTION(scope, false);
    return globalObject->moduleLoader()->removeEntry(key);
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionQueueMicrotask(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionQueueMicrotask_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    JSC::JSValue callback = args.callback;
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    JSC::JSValue asyncContext = globalObject->m_asyncContextData.get()->getInternalField(0);
#if ASSERT_ENABLED
    ASSERT_WITH_MESSAGE(!callback.isEmpty(), "Invalid microtask callback");
#endif

    if (asyncContext.isEmpty()) {
        asyncContext = JSC::jsUndefined();
    }

    // BunPerformMicrotaskJob: callback, asyncContext
    JSC::QueuedTask task { nullptr, JSC::InternalMicrotask::BunPerformMicrotaskJob, 0, globalObject, callback, asyncContext };
    globalObject->vm().queueMicrotask(WTF::move(task));
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_makeGetterTypeErrorForBuiltins(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_makeGetterTypeErrorForBuiltins_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const WTF::String& interfaceName = args.interfaceName;
    const WTF::String& attributeName = args.attributeName;
    VM& vm = globalObject->vm();
    DeferTermination deferScope(vm);

    auto error = static_cast<ErrorInstance*>(createTypeError(globalObject, JSC::makeDOMAttributeGetterTypeErrorMessage(interfaceName.utf8().data(), attributeName)));
    error->setNativeGetterTypeError();
    return error;
}

Bun::Bindgen::BuiltinExceptionResult Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_makeDOMExceptionForBuiltins(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_makeDOMExceptionForBuiltins_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    DeferTermination deferScope(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    const bool abort = args.code == "AbortError"_s;
    auto value = createDOMException(globalObject, abort ? WebCore::AbortError : WebCore::TypeError, args.message);
    EXCEPTION_ASSERT(!scope.exception() || vm.hasPendingTerminationException());
    Bun::Bindgen::BuiltinExceptionResult result;
    if (abort)
        result.set_dom_exception(value);
    else
        result.set_error(value);
    return result;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionEsmRegistryEvaluatedKeys(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionEsmRegistryEvaluatedKeys_Arguments&)
{
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::MarkedArgumentBuffer keys;
    for (auto& [key, entry] : globalObject->moduleLoader()->moduleMap()) {
        if (!key.first || !entry || !isModuleEvaluated(entry->record()))
            continue;
        auto* keyString = jsString(vm, String { key.first });
        RETURN_IF_EXCEPTION(scope, {});
        keys.append(keyString);
        if (keys.hasOverflowed()) [[unlikely]] {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
    }
    auto* array = JSC::constructArray(globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), keys);
    RETURN_IF_EXCEPTION(scope, {});
    return array;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionGetSelf(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionGetSelf_Arguments&)
{
    using namespace Zig;
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    return globalObject->globalThis();
}

Bun::Bindgen::CppAny Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_functionSetSelf(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_functionSetSelf_Arguments& args)
{
    auto& global = context.globalObject;
    auto& vm = global.vm();
    args.value.defineOwnDataProperty(vm, global, WebCore::builtinNames(vm).selfPublicName(), 0);
    return args.value;
}

Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionNotImplemented_Return::Type Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionNotImplemented(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionNotImplemented_Arguments&)
{
    return std::unexpected(BunBindgenCpp_GlobalObjectHost_jsFunctionNotImplemented_Return::Errors::not_implemented {});
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_getInternalWritableStream(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_getInternalWritableStream_Arguments& args)
{
    using namespace Zig;
    const std::optional<JSC::JSValue>& value = args.stream;
    auto* stream = writableStream(value);
    if (!stream) [[unlikely]]
        return std::nullopt;
    return stream->wrapped().internalWritableStream();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_createWritableStreamFromInternal(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_createWritableStreamFromInternal_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    JSC::JSValue streamValue = args.stream;
    auto* stream = JSC::asObject(streamValue);
    auto* jsDOMGlobalObject = uncheckedDowncast<JSDOMGlobalObject>(globalObject);
    auto internalWritableStream = InternalWritableStream::fromObject(*jsDOMGlobalObject, *stream);
    return toJSNewlyCreated(globalObject, jsDOMGlobalObject, WritableStream::create(WTF::move(internalWritableStream)));
}

Bun::Bindgen::AbortAlgorithmRegistrationResult Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_addAbortAlgorithmToSignal(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_addAbortAlgorithmToSignal_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const std::optional<JSC::JSValue>& signalValue = args.signal;
    JSC::JSValue algorithmValue = args.algorithm;
    Bun::Bindgen::AbortAlgorithmRegistrationResult result;
    auto* algorithm = JSC::asObject(algorithmValue);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* signal = abortSignal(signalValue);
    if (!signal) [[unlikely]] {
        result.set_unavailable(false);
        return result;
    }

    auto algorithmIdentifier = AbortSignal::addAbortAlgorithmToSignal(signal->wrapped(), *algorithm);
    RETURN_IF_EXCEPTION(scope, {});
    if (!algorithmIdentifier) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    result.set_identifier(*algorithmIdentifier);
    return result;
}

Bun::Bindgen::AbortAlgorithmRemovalResult Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_removeAbortAlgorithmFromSignal(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_removeAbortAlgorithmFromSignal_Arguments& args)
{
    using namespace Zig;
    const std::optional<JSC::JSValue>& signalValue = args.signal;
    uint32_t identifier = args.identifier;
    Bun::Bindgen::AbortAlgorithmRemovalResult result;
    auto* signal = abortSignal(signalValue);
    if (!signal) [[unlikely]] {
        result.set_unavailable(false);
        return result;
    }

    AbortSignal::removeAbortAlgorithmFromSignal(signal->wrapped(), identifier);
    result.set_removed(false);
    return result;
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionToClass(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionToClass_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    JSC::JSObject* target = asObject(args.target);
    const Bun::Bindgen::CppAny& name = args.name;
    const std::optional<JSC::JSValue>& baseValue = args.base;
    // Mimick the behavior of class Foo {} for a regular JSFunction.
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSObject* base = baseValue ? JSC::asObject(*baseValue) : nullptr;
    JSObject* prototypeBase = nullptr;

    if (!base) {
        base = globalObject->functionPrototype();
    } else {
        auto proto = base->getIfPropertyExists(globalObject, vm.propertyNames->prototype);
        RETURN_IF_EXCEPTION(scope, void());
        if (proto) {
            if (auto protoObject = proto.getObject()) {
                prototypeBase = protoObject;
            }
        } else {
            JSC::throwTypeError(globalObject, scope, "Base class must have a prototype property"_s);
            return;
        }
    }

    JSObject* prototype = prototypeBase ? JSC::constructEmptyObject(globalObject, prototypeBase) : JSC::constructEmptyObject(globalObject);
    RETURN_IF_EXCEPTION(scope, void());

    prototype->structure()->setMayBePrototype(true);
    prototype->putDirect(vm, vm.propertyNames->constructor, target, PropertyAttribute::DontEnum | 0);

    target->setPrototypeDirect(vm, base);
    target->putDirect(vm, vm.propertyNames->prototype, prototype, PropertyAttribute::DontEnum | 0);
    name.defineOwnDataProperty(vm, *target, vm.propertyNames->name, static_cast<unsigned>(PropertyAttribute::DontEnum));
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionPerformMicrotaskVariadic(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionPerformMicrotaskVariadic_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* globalObject = &context.globalObject;
    const std::optional<JSC::JSValue>& job = args.job;
    const Bun::Bindgen::CppLazyArgument<JSC::JSValue>& arguments = args.arguments;
    JSC::JSValue asyncContext = args.asyncContext;
    const std::optional<JSC::JSValue>& thisValue = args.thisValue;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (!job)
        return;

    const auto invoke = [&] {
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto callData = JSC::getCallData(*job);
        MarkedArgumentBuffer jobArguments;
        ASSERT(callData.type != CallData::Type::None);

        const auto* convertedArguments = arguments.convert();
        RETURN_IF_EXCEPTION(scope, void());
        if (!convertedArguments)
            return;
        JSArray* array = uncheckedDowncast<JSC::JSArray>(*convertedArguments);
        unsigned length = array->length();
        for (unsigned i = 0; i < length; i++) {
            JSValue argument = array->getIndex(globalObject, i);
            RETURN_IF_EXCEPTION(scope, void());
            jobArguments.append(argument);
            if (jobArguments.hasOverflowed()) {
                throwOutOfMemoryError(globalObject, scope);
                return;
            }
        }

        AsyncContextSwapScope asyncContextScope(vm, globalObject, asyncContext);

        JSC::profiledCall(globalObject, ProfilingReason::API, *job, callData, thisValue.value_or(jsUndefined()), jobArguments);
        asyncContextScope.restoreEarly();
    };
    invoke();

    if (auto* exception = scope.exception()) {
        if (scope.clearExceptionExceptTermination())
            Zig::GlobalObject::reportUncaughtExceptionAtEventLoop(globalObject, exception);
    }
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionAddEventListener(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionAddEventListener_Arguments& args)
{
    auto listener = createEventListener(context.globalObject, args.listener, context.globalObject);
    auto options = args.options
        ? materializeEventListenerOptions(*args.options)
        : WebCore::EventTarget::AddEventListenerOptionsOrBoolean { false };
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    globalObject->globalEventScope->addEventListenerForBindings(
        context.globalObject, AtomString { args.type }, WTF::move(listener), WTF::move(options));
    RETURN_IF_EXCEPTION(scope, void());
    context.globalObject.vm().writeBarrier(globalObject, Bun::Bindgen::eventListenerValue(args.listener));
}

void Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionRemoveEventListener(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionRemoveEventListener_Arguments& args)
{
    auto listener = createEventListener(context.globalObject, args.listener, context.globalObject);
    auto options = args.options
        ? materializeEventListenerOptions(*args.options)
        : WebCore::EventTarget::EventListenerOptionsOrBoolean { false };
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    globalObject->globalEventScope->removeEventListenerForBindings(
        AtomString { args.type }, WTF::move(listener), WTF::move(options));
    context.globalObject.vm().writeBarrier(globalObject, Bun::Bindgen::eventListenerValue(args.listener));
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_jsFunctionDispatchEvent(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_jsFunctionDispatchEvent_Arguments& args)
{
    using namespace Zig;
    JSC::JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    WebCore::Event* event = args.event;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto result = globalObject->globalEventScope->dispatchEventForBindings(*event);
    if (result.hasException()) {
        propagateException(*lexicalGlobalObject, scope, result.releaseException());
        return false;
    }
    return result.releaseReturnValue();
}

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, Callback)                                      \
    JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                                 \
        Bun::Bindgen::CppCallContext& context,                                                          \
        const Bun::Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)                  \
    {                                                                                                   \
        return Callback(context.globalObject.vm(), JSC::asObject(args.bindingThis));                     \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(GlobalObjectHost, GlobalObject_getGlobalThis, Zig::GlobalObject_getGlobalThis)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(GlobalObjectHost, GlobalObject_getPerformanceObject, Zig::GlobalObject_getPerformanceObject)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_arrayBufferConstructorValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_arrayBufferConstructorValue_Arguments&)
{
    return static_cast<Zig::GlobalObject&>(context.globalObject).arrayBufferConstructor();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_internalModuleRegistryValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_internalModuleRegistryValue_Arguments&)
{
    return static_cast<Zig::GlobalObject&>(context.globalObject).internalModuleRegistry();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_processBindingConstantsValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_processBindingConstantsValue_Arguments&)
{
    return static_cast<Zig::GlobalObject&>(context.globalObject).processBindingConstants();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_requireMapValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_requireMapValue_Arguments&)
{
    return static_cast<Zig::GlobalObject&>(context.globalObject).requireMap();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_textEncoderStreamEncoderConstructorValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_textEncoderStreamEncoderConstructorValue_Arguments&)
{
    return static_cast<Zig::GlobalObject&>(context.globalObject).BunBindgen_TextEncoderStreamEncoder_TextEncoderStreamEncoderConstructor();
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_readableStreamNativeMapValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_readableStreamNativeMapValue_Arguments&)
{
    return static_cast<Zig::GlobalObject&>(context.globalObject).readableStreamNativeMap();
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_globalOnMessageValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_globalOnMessageValue_Arguments&)
{
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    return eventHandlerAttribute(global.eventTarget(), eventNames().messageEvent, global.world());
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_setGlobalOnMessageValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_setGlobalOnMessageValue_Arguments& args)
{
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    setEventHandlerAttribute<JSEventListener>(context.globalObject, global.eventTarget(), eventNames().messageEvent, args.value, global);
    return true;
}

std::optional<JSC::JSValue> Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_globalOnErrorValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_globalOnErrorValue_Arguments&)
{
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    return eventHandlerAttribute(global.eventTarget(), eventNames().errorEvent, global.world());
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_setGlobalOnErrorValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_setGlobalOnErrorValue_Arguments& args)
{
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    setEventHandlerAttribute<JSEventListener>(context.globalObject, global.eventTarget(), eventNames().errorEvent, args.value, global);
    return true;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_errorPrepareStackTraceValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_errorPrepareStackTraceValue_Arguments&)
{
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    if (global.m_errorConstructorPrepareStackTraceValue)
        return global.m_errorConstructorPrepareStackTraceValue.get();
    return global.m_errorConstructorPrepareStackTraceInternalValue.get(&global);
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_setErrorPrepareStackTraceValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_setErrorPrepareStackTraceValue_Arguments& args)
{
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    if (args.value == global.m_errorConstructorPrepareStackTraceInternalValue.get(&global))
        global.m_errorConstructorPrepareStackTraceValue.clear();
    else
        global.m_errorConstructorPrepareStackTraceValue.set(global.vm(), &global, args.value);
    return true;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_consoleConstructorValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_consoleConstructorValue_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* createConsoleConstructor = JSC::JSFunction::create(vm, &context.globalObject, consoleObjectCreateConsoleConstructorCodeGenerator(vm), &context.globalObject);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(args.bindingThis);
    auto result = JSC::profiledCall(&context.globalObject, ProfilingReason::API, createConsoleConstructor, JSC::getCallData(createConsoleConstructor), args.bindingThis, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    JSC::asObject(args.bindingThis)->putDirect(vm, JSC::Identifier::fromString(vm, "Console"_s), result, 0);
    RELEASE_AND_RETURN(scope, result);
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_consoleStdoutValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_consoleStdoutValue_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    auto value = global.processObject()->get(&global, JSC::Identifier::fromString(vm, "stdout"_s));
    if (!value)
        return {};
    JSC::asObject(args.bindingThis)->putDirect(vm, JSC::Identifier::fromString(vm, "_stdout"_s), value, JSC::PropertyAttribute::DontEnum | 0);
    return value;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_consoleStderrValue(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_consoleStderrValue_Arguments& args)
{
    auto& vm = context.globalObject.vm();
    auto& global = static_cast<Zig::GlobalObject&>(context.globalObject);
    auto value = global.processObject()->get(&global, JSC::Identifier::fromString(vm, "stderr"_s));
    if (!value)
        return {};
    JSC::asObject(args.bindingThis)->putDirect(vm, JSC::Identifier::fromString(vm, "_stderr"_s), value, JSC::PropertyAttribute::DontEnum | 0);
    return value;
}

std::optional<bool> Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_moduleNamespaceESModuleValue(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_moduleNamespaceESModuleValue_Arguments& args)
{
    auto* object = args.bindingThis
        ? dynamicDowncast<JSC::JSModuleNamespaceObject>(*args.bindingThis)
        : nullptr;
    RELEASE_ASSERT(!args.bindingThis || object);
    if (!object || object->m_hasESModuleMarker != WTF::TriState::True)
        return std::nullopt;
    return true;
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_GlobalObjectHost_setModuleNamespaceESModuleValue(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_GlobalObjectHost_setModuleNamespaceESModuleValue_Arguments& args)
{
    auto* object = args.bindingThis
        ? dynamicDowncast<JSC::JSModuleNamespaceObject>(*args.bindingThis)
        : nullptr;
    RELEASE_ASSERT(!args.bindingThis || object);
    if (!object)
        return false;
    object->m_hasESModuleMarker = args.value ? WTF::TriState::True : WTF::TriState::False;
    return true;
}
