#include "config.h"
#include "JSPerformanceObserver.h"

#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSPerformanceEntry.h"
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SlotVisitorMacros.h>

namespace WebCore {

using namespace JSC;

template<typename Visitor>
void PerformanceObserver::visitCallback(Visitor& visitor)
{
    visitor.append(m_callback);
}

template void PerformanceObserver::visitCallback(JSC::AbstractSlotVisitor&);
template void PerformanceObserver::visitCallback(JSC::SlotVisitor&);

void PerformanceObserver::invokeCallback(JSObject& callback, std::span<const RefPtr<PerformanceEntry>> entries)
{
    auto& globalObject = *uncheckedDowncast<JSDOMGlobalObject>(callback.globalObject());
    if (!globalObject.scriptExecutionContext())
        return;
    auto& vm = globalObject.vm();
    JSLockHolder lock(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    const auto invoke = [&] {
        auto invocationScope = DECLARE_THROW_SCOPE(vm);
        JSValue thisValue = toJS(&globalObject, &globalObject, *this);
        RETURN_IF_EXCEPTION(invocationScope, void());

        MarkedArgumentBuffer values;
        for (const auto& entry : entries) {
            RELEASE_ASSERT(entry);
            values.append(toJS(&globalObject, &globalObject, *entry));
            RETURN_IF_EXCEPTION(invocationScope, void());
            if (values.hasOverflowed()) {
                throwOutOfMemoryError(&globalObject, invocationScope);
                return;
            }
        }
        auto* array = constructArray(&globalObject, static_cast<ArrayAllocationProfile*>(nullptr), values);
        RETURN_IF_EXCEPTION(invocationScope, void());

        auto factory = bun_bindgen_source_function_WebCorePerformance_createObserverEntryList_value(defaultGlobalObject(&globalObject));
        RETURN_IF_EXCEPTION(invocationScope, void());
        MarkedArgumentBuffer factoryArgs;
        factoryArgs.append(array);
        if (factoryArgs.hasOverflowed()) {
            throwOutOfMemoryError(&globalObject, invocationScope);
            return;
        }
        auto list = profiledCall(&globalObject, ProfilingReason::API, factory, getCallData(factory), jsUndefined(), factoryArgs);
        RETURN_IF_EXCEPTION(invocationScope, void());

        MarkedArgumentBuffer args;
        args.append(list);
        args.append(thisValue);
        if (args.hasOverflowed()) {
            throwOutOfMemoryError(&globalObject, invocationScope);
            return;
        }
        auto callData = getCallData(&callback);
        RELEASE_ASSERT(callData.type != CallData::Type::None);
        profiledCall(&globalObject, ProfilingReason::Other, &callback, callData, thisValue, args);
        RETURN_IF_EXCEPTION(invocationScope, void());
    };
    if (!scope.exception())
        invoke();
    if (auto* exception = scope.exception())
        reportException(&globalObject, exception);
    ensureStillAliveHere(&callback);
}

bool JSPerformanceObserverOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor&, ASCIILiteral* reason)
{
    if (reason) [[unlikely]]
        *reason = "PerformanceObserver registration or pending delivery"_s;

    auto& observer = uncheckedDowncast<JSPerformanceObserver>(handle.slot()->asCell())->wrapped();
    return observer.isRegistered() || observer.hasPendingDelivery();
}

void JSPerformanceObserverOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSPerformanceObserver*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCorePerformance_PerformanceObserver::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().visitCallback(visitor);
}

template void BunBindgen_WebCorePerformance_PerformanceObserver::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCorePerformance_PerformanceObserver::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen {
namespace Cpp {

JSPerformanceObserver* bunBindgenCpp_WebCorePerformance_PerformanceObserver_construct(
    CppEngineConstructContext<JSPerformanceObserver>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceObserver_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*global, throwScope, "PerformanceObserver"_s);
        return nullptr;
    }

    auto performance = zigGlobal->tryPerformance();
    if (!performance) {
        throwOutOfMemoryError(global, throwScope);
        return nullptr;
    }
    auto impl = PerformanceObserver::tryCreate(*performance, *asObject(args.callback));
    if (!impl) {
        throwOutOfMemoryError(global, throwScope);
        return nullptr;
    }
    auto* implPtr = impl.get();
    auto* wrapper = JSPerformanceObserver::create(ctx.structure, zigGlobal, impl.releaseNonNull());
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    global->vm().writeBarrier(wrapper, args.callback);
    return wrapper;
}

void bunBindgenCpp_WebCorePerformance_PerformanceObserver_method_observe(
    CppEngineCallContext<JSPerformanceObserver>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceObserver_method_observe_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    PerformanceObserver::Init init;
    if (const auto& dict = args.options) {
        init.buffered = dict->buffered;
        if (dict->entry_types)
            init.entryTypes = dict->entry_types->span();
        if (dict->type)
            init.type = *dict->type;
    } else {
        init.buffered = false;
    }
    invokeFunctorPropagatingExceptionIfNecessary(*global, throwScope, [&] {
        return ctx.wrapped().observe(init);
    });
}

void bunBindgenCpp_WebCorePerformance_PerformanceObserver_method_disconnect(
    CppEngineCallContext<JSPerformanceObserver>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceObserver_method_disconnect_Arguments&)
{
    ctx.wrapped().disconnect();
}

CppResultSequence<JSValue> bunBindgenCpp_WebCorePerformance_PerformanceObserver_method_takeRecords(
    CppEngineCallContext<JSPerformanceObserver>& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceObserver_method_takeRecords_Arguments&)
{
    auto& global = ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto entries = ctx.wrapped().takeRecords();
    CppResultSequence<JSValue> result;
    if (!result.reserveCapacity(ctx.results(), entries.size()))
        return {};
    auto* domGlobal = defaultGlobalObject(&global);
    for (const auto& entry : entries) {
        RELEASE_ASSERT(entry);
        auto value = toJS(&global, domGlobal, *entry);
        RETURN_IF_EXCEPTION(scope, {});
        if (!result.append(ctx.results(), value))
            return {};
    }
    return result;
}

WTF::Vector<WTF::String> bunBindgenCpp_WebCorePerformance_PerformanceObserver_static_getter_supportedEntryTypes(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCorePerformance_PerformanceObserver_static_getter_supportedEntryTypes_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    WTF::Vector<WTF::String> entryTypes;
    if (!entryTypes.tryReserveInitialCapacity(3)) {
        throwOutOfMemoryError(global, scope);
        return {};
    }
    entryTypes.append("mark"_s);
    entryTypes.append("measure"_s);
    entryTypes.append("resource"_s);
    return entryTypes;
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
