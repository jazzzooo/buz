#include "config.h"
#include "JSWorker.h"

#include "BunProcess.h"
#include "DOMURL.h"
#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMURL.h"
#include "JSDOMWrapperCache.h"
#include "JSEventListener.h"
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "SerializedScriptValue.h"
#include "StructuredSerializeBinding.h"
#include "StructuredSerializeOptions.h"
#include "WorkerOptions.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/BunV8HeapSnapshotBuilder.h>
#include <JavaScriptCore/HeapProfiler.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <memory>
#include <wtf/Scope.h>

namespace WebCore {

using namespace JSC;

bool JSWorkerOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSWorker>(handle.slot()->asCell());
    auto& wrapped = wrapper->wrapped();
    if (!wrapped.isContextStopped() && wrapped.hasPendingActivity()) {
        if (reason) [[unlikely]]
            *reason = "ActiveDOMObject with pending activity"_s;
        return true;
    }
    if (reason) [[unlikely]]
        *reason = "Reachable from Event"_s;
    return visitor.containsOpaqueRoot(static_cast<EventTarget*>(&wrapped));
}

void JSWorkerOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSWorker*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

static String workerScriptURL(JSGlobalObject& global, const WorkerScriptURLInput& input)
{
    if (input.is_string())
        return input.string();
    RELEASE_ASSERT(input.is_url());
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto url = protectedDOMURL(&global, input.url());
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(url);
    auto snapshot = url->href();
    if (snapshot.hasException()) {
        propagateException(global, scope, snapshot.releaseException());
        return {};
    }
    return snapshot.releaseReturnValue().string();
}

static bool copyCurrentWorkerEnvironment(
    JSGlobalObject& lexicalGlobalObject,
    Zig::GlobalObject& globalObject,
    WorkerOptions& options)
{
    if (!globalObject.m_processEnvObject.isInitialized())
        return true;

    auto& vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* environment = globalObject.processEnvObject();
    if (!environment->staticPropertiesReified()) {
        environment->reifyAllStaticProperties(&globalObject);
        RETURN_IF_EXCEPTION(scope, false);
    }

    PropertyNameArrayBuilder keys(vm, PropertyNameMode::Strings, PrivateSymbolMode::Exclude);
    environment->methodTable()->getOwnPropertyNames(environment, &lexicalGlobalObject, keys, DontEnumPropertiesMode::Exclude);
    RETURN_IF_EXCEPTION(scope, false);

    HashMap<String, String> values;
    for (const auto& key : keys) {
        auto value = environment->get(&lexicalGlobalObject, key);
        RETURN_IF_EXCEPTION(scope, false);
        auto string = value.toWTFString(&lexicalGlobalObject).isolatedCopy();
        RETURN_IF_EXCEPTION(scope, false);
        values.add(key.impl()->isolatedCopy(), WTF::move(string));
    }
    options.env.emplace(WTF::move(values));
    return true;
}

static String workerArgumentString(const WorkerArgumentInput& argument)
{
    if (argument.is_value())
        return argument.value().isolatedCopy();
    RELEASE_ASSERT(argument.is_symbol());
    return asSymbol(argument.symbol())->tryGetDescriptiveString().value_or(String()).isolatedCopy();
}

static bool populateWorkerOptions(
    JSGlobalObject& lexicalGlobalObject,
    Zig::GlobalObject& globalObject,
    const WorkerOptionsInput& input,
    WorkerOptions& options,
    Strong<Unknown>& workerData,
    Vector<Strong<JSObject>>& transferList)
{
    auto& vm = lexicalGlobalObject.vm();

    if (input.name)
        options.name = input.name->isolatedCopy();
    if (input.smol)
        options.mini = *input.smol;
    if (input.ref)
        options.unref = !*input.ref;
    if (input.eval)
        options.evalMode = *input.eval;

    if (input.preload && *input.preload) {
        const auto& preload = **input.preload;
        if (preload.is_module()) {
            if (!preload.module().isEmpty())
                options.preloadModules.append(preload.module().isolatedCopy());
        } else {
            RELEASE_ASSERT(preload.is_modules());
            options.preloadModules.reserveInitialCapacity(preload.modules().size());
            for (const auto& module : preload.modules()) {
                if (!module.isEmpty())
                    options.preloadModules.append(module.isolatedCopy());
            }
        }
    }

    auto data = jsUndefined();
    if (input.workerData)
        data = *input.workerData;
    workerData.set(vm, data);

    if (input.transferList) {
        transferList.reserveInitialCapacity(input.transferList->size());
        for (auto value : *input.transferList) {
            auto* object = value.getObject();
            RELEASE_ASSERT(object);
            transferList.append({ vm, object });
        }
    }

    if (input.env) {
        if (input.env->is_record()) {
            HashMap<String, String> values;
            values.reserveInitialCapacity(input.env->record().size());
            for (const auto& entry : input.env->record())
                values.add(entry.first.isolatedCopy(), entry.second.isolatedCopy());
            options.env.emplace(WTF::move(values));
        } else {
            RELEASE_ASSERT(input.env->is_shared());
        }
    } else if (!copyCurrentWorkerEnvironment(lexicalGlobalObject, globalObject, options)) {
        return false;
    }

    if (input.argv) {
        options.argv.reserveInitialCapacity(input.argv->size());
        for (const auto& argument : *input.argv)
            options.argv.append(workerArgumentString(argument));
    }
    if (input.execArgv) {
        Vector<String> arguments;
        arguments.reserveInitialCapacity(input.execArgv->size());
        for (const auto& argument : *input.execArgv)
            arguments.append(workerArgumentString(argument));
        options.execArgv.emplace(WTF::move(arguments));
    }

    return true;
}

JSWorker* bunBindgenCpp_WebCoreWorker_Worker_construct(
    CppEngineConstructContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_construct_Arguments& args)
{
    auto* lexicalGlobalObject = &ctx.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* context = globalObject->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*lexicalGlobalObject, throwScope, "Worker"_s);
        return nullptr;
    }

    String scriptUrl = workerScriptURL(*lexicalGlobalObject, args.filename);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    WorkerOptions options;
    Strong<Unknown> rootedWorkerData;
    rootedWorkerData.set(vm, jsUndefined());
    Vector<Strong<JSObject>> transferList;
    if (args.options.is_options()) {
        bool populated = populateWorkerOptions(*lexicalGlobalObject, *globalObject, args.options.options(), options, rootedWorkerData, transferList);
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        if (!populated)
            return nullptr;
    }

    const bool isNodeWorker = args.nodeWorkerObject.has_value();
    if (isNodeWorker)
        options.kind = WorkerOptions::Kind::Node;

    auto* valueToTransfer = constructEmptyArray(globalObject, nullptr, 2);
    RETURN_IF_EXCEPTION(throwScope, {});
    valueToTransfer->putDirectIndex(globalObject, 0, rootedWorkerData.get());
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    auto* environmentData = globalObject->nodeWorkerEnvironmentData();
    // If node:worker_threads has not been imported, environment data will not be set up yet.
    valueToTransfer->putDirectIndex(globalObject, 1, environmentData ? environmentData : jsUndefined());
    RETURN_IF_EXCEPTION(throwScope, nullptr);

    auto prepared = MessagePort::prepareMessage(*lexicalGlobalObject, valueToTransfer, WTF::move(transferList));
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (prepared.hasException()) {
        WebCore::propagateException(*lexicalGlobalObject, throwScope, prepared.releaseException());
        return nullptr;
    }
    auto createResult = Worker::prepare(*context, WTF::move(scriptUrl), WTF::move(options));
    if (createResult.hasException()) [[unlikely]] {
        RETURN_IF_EXCEPTION(throwScope, nullptr);
        WebCore::propagateException(*lexicalGlobalObject, throwScope, createResult.releaseException());
        return nullptr;
    }
    auto impl = createResult.releaseReturnValue();
    auto cancelStartup = makeScopeExit([&] { impl->cancelStartup(); });
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    auto* implPtr = impl.ptr();
    auto* wrapper = JSWorker::create(ctx.structure, globalObject, Ref { impl.get() });
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    cacheWrapper(globalObject->world(), implPtr, wrapper);

    JSValue workerToEmit = isNodeWorker ? *args.nodeWorkerObject : JSValue { wrapper };
    auto* process = globalObject->processObject();
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    auto notification = process->prepareEmitOnNextTick(globalObject, "worker"_s, workerToEmit);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!notification)
        return nullptr;

    auto committed = impl->commitStartup(*lexicalGlobalObject, prepared.releaseReturnValue());
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (committed.hasException()) {
        WebCore::propagateException(*lexicalGlobalObject, throwScope, committed.releaseException());
        return nullptr;
    }
    notification->commit();
    cancelStartup.release();

    return wrapper;
}

static std::optional<JSValue> workerEventHandler(CppEngineCallContext<JSWorker>& ctx, const AtomString& eventType)
{
    return eventHandlerAttribute(ctx.wrapped(), eventType, worldForDOMObject(ctx.wrapper));
}

static void setWorkerEventHandler(CppEngineCallContext<JSWorker>& ctx, const AtomString& eventType, const std::optional<JSValue>& value)
{
    setEventHandlerAttribute<JSEventListener>(ctx.globalObject, ctx.wrapped(), eventType, value, ctx.wrapper);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWorker_Worker_getter_onerror(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_getter_onerror_Arguments&)
{
    return workerEventHandler(ctx, eventNames().errorEvent);
}

void bunBindgenCpp_WebCoreWorker_Worker_setter_onerror(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_setter_onerror_Arguments& args)
{
    setWorkerEventHandler(ctx, eventNames().errorEvent, args.value);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWorker_Worker_getter_onmessage(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_getter_onmessage_Arguments&)
{
    return workerEventHandler(ctx, eventNames().messageEvent);
}

void bunBindgenCpp_WebCoreWorker_Worker_setter_onmessage(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_setter_onmessage_Arguments& args)
{
    setWorkerEventHandler(ctx, eventNames().messageEvent, args.value);
}

std::optional<JSValue> bunBindgenCpp_WebCoreWorker_Worker_getter_onmessageerror(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_getter_onmessageerror_Arguments&)
{
    return workerEventHandler(ctx, eventNames().messageerrorEvent);
}

void bunBindgenCpp_WebCoreWorker_Worker_setter_onmessageerror(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_setter_onmessageerror_Arguments& args)
{
    setWorkerEventHandler(ctx, eventNames().messageerrorEvent, args.value);
}

void bunBindgenCpp_WebCoreWorker_Worker_method_postMessage(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_method_postMessage_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto& impl = ctx.wrapped();
    auto* zigGlobal = defaultGlobalObject(global);
    auto options = structuredSerializeOptionsFromBinding(ctx.globalObject, args.second);
    RETURN_IF_EXCEPTION(throwScope, );
    RELEASE_ASSERT(options);
    invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] {
        return impl.postMessage(*zigGlobal, args.message, WTF::move(*options));
    });
}

void bunBindgenCpp_WebCoreWorker_Worker_method_ref(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_method_ref_Arguments&)
{
    ctx.wrapped().setKeepAlive(true);
}

void bunBindgenCpp_WebCoreWorker_Worker_method_unref(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_method_unref_Arguments&)
{
    ctx.wrapped().setKeepAlive(false);
}

void bunBindgenCpp_WebCoreWorker_Worker_method_terminate(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_method_terminate_Arguments&)
{
    ctx.wrapped().terminate();
}

int32_t bunBindgenCpp_WebCoreWorker_Worker_getter_threadId(
    CppEngineCallContext<JSWorker>& ctx,
    const BunBindgenCpp_WebCoreWorker_Worker_getter_threadId_Arguments&)
{
    auto& worker = ctx.wrapped();
    if (worker.wasTerminated())
        return -1;
    // Main thread starts at 1
    //
    // Note that we cannot use posix thread ids here because we don't know their thread id until the thread starts
    //
    return static_cast<int32_t>(worker.clientIdentifier() - 1);
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun

namespace Bun::Bindgen::Engine {

void releaseWebWorkerState(Bun::WebWorkerState* worker)
{
    ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerDestroy(worker);
}

void releaseWorkerHeapSnapshotTask(Bun::WorkerHeapSnapshotTask* task)
{
    ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerHeapSnapshotTaskRejectNotRunning(task);
}

struct WorkerHeapSnapshotTaskDeleter {
    void operator()(Bun::WorkerHeapSnapshotTask* task) const
    {
        releaseWorkerHeapSnapshotTask(task);
    }
};

void bunBindgenEngine_WebWorkerEngine_webWorkerStartHeapSnapshot(
    const BunBindgenEngine_WebWorkerEngine_webWorkerStartHeapSnapshot_Arguments& args)
{
    std::unique_ptr<Bun::WorkerHeapSnapshotTask, WorkerHeapSnapshotTaskDeleter> task(args.task);
    args.worker->postTaskToWorkerGlobalScope([task = WTF::move(task)](WebCore::ScriptExecutionContext& workerContext) mutable {
        auto& vm = workerContext.vm();
        vm.ensureHeapProfiler();
        auto& heapProfiler = *vm.heapProfiler();
        heapProfiler.clearSnapshots();
        JSC::BunV8HeapSnapshotBuilder builder(heapProfiler);
        WTF::String snapshot = builder.json();
        ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerHeapSnapshotTaskResolve(task.release(), snapshot);
    });
}

} // namespace Bun::Bindgen::Engine
