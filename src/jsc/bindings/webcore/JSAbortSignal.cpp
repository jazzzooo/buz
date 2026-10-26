#include "config.h"
#include "JSAbortSignal.h"

#include "ErrorCode.h"
#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSEventListener.h"
#include "ScriptExecutionContext.h"
#include "WebCoreJSClientData.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>

namespace WebCore {

using namespace JSC;

bool JSAbortSignalOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    auto& abortSignal = uncheckedDowncast<JSAbortSignal>(handle.slot()->asCell())->wrapped();
    if (abortSignal.isFiringEventListeners()) {
        if (reason) [[unlikely]]
            *reason = "EventTarget firing event listeners"_s;
        return true;
    }

    // A live wrapper elsewhere roots this signal (AbortController.signal,
    // a dependent signal's sources): keep wrapper identity and expandos
    // even after the signal aborts.
    if (visitor.containsOpaqueRoot(&abortSignal) || visitor.containsOpaqueRoot(static_cast<EventTarget*>(&abortSignal))) {
        if (reason) [[unlikely]]
            *reason = "Reachable from opaque roots"_s;
        return true;
    }

    if (abortSignal.aborted())
        return false;

    if (abortSignal.hasAbortEventListener()) {
        if (abortSignal.hasActiveTimeoutTimer()) {
            if (reason) [[unlikely]]
                *reason = "Has Timeout And Abort Event Listener"_s;
            return true;
        }
        if (abortSignal.isDependent()) {
            // isEmptyIgnoringNullReferences() prunes dead entries, which is
            // not safe on GC marker threads; compare iterators to keep the
            // emptiness check read-only.
            auto& sourceSignals = abortSignal.sourceSignals();
            if (sourceSignals.begin() != sourceSignals.end()) {
                if (reason) [[unlikely]]
                    *reason = "Has Source Signals And Abort Event Listener"_s;
                return true;
            }
        }

        // https://github.com/oven-sh/bun/issues/4517
        if (abortSignal.hasPendingActivity()) {
            if (reason) [[unlikely]]
                *reason = "Has Pending Activity"_s;
            return true;
        }
    }

    return false;
}

void JSAbortSignalOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSAbortSignal*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCoreEvents_AbortSignal::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().reason().visit(visitor);
    wrapped().visitAbortAlgorithms(visitor);
}

template void BunBindgen_WebCoreEvents_AbortSignal::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_AbortSignal::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen {
namespace Cpp {

bool bunBindgenCpp_WebCoreEvents_AbortSignal_getter_aborted(
    CppEngineCallContext<JSAbortSignal>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_getter_aborted_Arguments&)
{
    return ctx.wrapped().aborted();
}

JSValue bunBindgenCpp_WebCoreEvents_AbortSignal_getter_reason(
    CppEngineCallContext<JSAbortSignal>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_getter_reason_Arguments&)
{
    return ctx.wrapped().jsReason(ctx.globalObject);
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_AbortSignal_getter_onabort(
    CppEngineCallContext<JSAbortSignal>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_getter_onabort_Arguments&)
{
    return eventHandlerAttribute(ctx.wrapped(), eventNames().abortEvent, worldForDOMObject(ctx.wrapper));
}

void bunBindgenCpp_WebCoreEvents_AbortSignal_setter_onabort(
    CppEngineCallContext<JSAbortSignal>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_setter_onabort_Arguments& args)
{
    setEventHandlerAttribute<JSEventListener>(ctx.globalObject, ctx.wrapped(), eventNames().abortEvent, args.value, ctx.wrapper);
}

void bunBindgenCpp_WebCoreEvents_AbortSignal_method_throwIfAborted(
    CppEngineCallContext<JSAbortSignal>& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_method_throwIfAborted_Arguments&)
{
    ctx.wrapped().throwIfAborted(ctx.globalObject);
}

JSValue bunBindgenCpp_WebCoreEvents_AbortSignal_static_method_abort(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_static_method_abort_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]]
        return jsUndefined();
    auto signal = AbortSignal::abort(*zigGlobal, *context, args.reason.value_or(jsUndefined()));
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, toJSNewlyCreated(global, zigGlobal, signal.releaseNonNull()));
}

JSValue bunBindgenCpp_WebCoreEvents_AbortSignal_static_method_timeout(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_static_method_timeout_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]]
        return jsUndefined();
    RELEASE_AND_RETURN(scope, toJSNewlyCreated(global, zigGlobal, AbortSignal::timeout(*context, args.milliseconds)));
}

BunBindgenCpp_WebCoreEvents_AbortSignal_static_method_any_Return::Type bunBindgenCpp_WebCoreEvents_AbortSignal_static_method_any(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCoreEvents_AbortSignal_static_method_any_Arguments& args)
{
    using Errors = BunBindgenCpp_WebCoreEvents_AbortSignal_static_method_any_Return::Errors;
    if (!args.signals)
        return std::unexpected(Errors::missing_signals {});
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]]
        return jsUndefined();
    Vector<RefPtr<AbortSignal>> signals;
    if (!signals.tryReserveInitialCapacity(args.signals->size()))
        return nativeAllocationFailure();
    for (auto* signal : *args.signals)
        signals.unsafeAppendWithoutCapacityCheck(signal);
    auto signal = AbortSignal::any(*zigGlobal, *context, signals);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, toJSNewlyCreated(global, zigGlobal, signal.releaseNonNull()));
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
