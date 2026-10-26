#include "config.h"
#include "JSErrorEvent.h"

#include "JSDOMWrapperCache.h"
#include "EventNames.h"
#include "EventTarget.h"
#include "JSDOMExceptionHandling.h"
#include "ScriptExecutionContext.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/TopExceptionScope.h>

namespace WebCore {

void ErrorEvent::dispatch(EventTarget& target, const Init& init, IsTrusted isTrusted)
{
    Ref protectedTarget { target };
    auto* context = target.scriptExecutionContext();
    if (!context)
        return;
    auto* global = context->globalObject();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
    // Callback lookup can run JS before an event wrapper exists to trace the payload.
    JSC::EnsureStillAliveScope payload { init.error };
    if (!scope.exception()) {
        auto event = tryCreate(eventNames().errorEvent, init, isTrusted);
        if (event)
            target.dispatchEvent(*event);
        else {
            auto throwScope = DECLARE_THROW_SCOPE(global->vm());
            JSC::throwOutOfMemoryError(global, throwScope);
        }
    }
    if (auto* exception = scope.exception())
        reportException(global, exception);
}

}

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCoreEvents_ErrorEvent::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().originalError().visit(visitor);
}

template void BunBindgen_WebCoreEvents_ErrorEvent::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_ErrorEvent::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen {
namespace Cpp {

JSErrorEvent* bunBindgenCpp_WebCoreEvents_ErrorEvent_construct(
    CppEngineConstructContext<JSErrorEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_ErrorEvent_construct_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(ctx.globalObject.vm());
    auto* zigGlobal = defaultGlobalObject(&ctx.globalObject);
    ErrorEvent::Init init;
    if (const auto& dict = args.eventInitDict) {
        init.bubbles = dict->bubbles;
        init.cancelable = dict->cancelable;
        init.composed = dict->composed;
        init.colno = dict->colno;
        init.error = dict->error;
        init.filename = dict->filename;
        init.lineno = dict->lineno;
        init.message = dict->message;
    } else {
        init.error = jsNull();
        init.filename = emptyString();
        init.message = emptyString();
    }
    auto impl = ErrorEvent::tryCreate(AtomString { args.type }, init);
    if (!impl) {
        throwOutOfMemoryError(&ctx.globalObject, scope);
        return nullptr;
    }
    auto* implPtr = impl.get();
    auto* wrapper = JSErrorEvent::create(ctx.structure, zigGlobal, impl.releaseNonNull());
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    ctx.globalObject.vm().writeBarrier(wrapper, init.error);
    return wrapper;
}

WTF::String bunBindgenCpp_WebCoreEvents_ErrorEvent_getter_message(
    CppEngineCallContext<JSErrorEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_ErrorEvent_getter_message_Arguments&)
{
    return ctx.wrapped().message();
}

WTF::String bunBindgenCpp_WebCoreEvents_ErrorEvent_getter_filename(
    CppEngineCallContext<JSErrorEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_ErrorEvent_getter_filename_Arguments&)
{
    return ctx.wrapped().filename();
}

uint32_t bunBindgenCpp_WebCoreEvents_ErrorEvent_getter_lineno(
    CppEngineCallContext<JSErrorEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_ErrorEvent_getter_lineno_Arguments&)
{
    return ctx.wrapped().lineno();
}

uint32_t bunBindgenCpp_WebCoreEvents_ErrorEvent_getter_colno(
    CppEngineCallContext<JSErrorEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_ErrorEvent_getter_colno_Arguments&)
{
    return ctx.wrapped().colno();
}

JSValue bunBindgenCpp_WebCoreEvents_ErrorEvent_getter_error(
    CppEngineCallContext<JSErrorEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_ErrorEvent_getter_error_Arguments&)
{
    return ctx.wrapped().error();
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
