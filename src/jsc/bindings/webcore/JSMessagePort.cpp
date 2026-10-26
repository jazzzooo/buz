#include "config.h"
#include "JSMessagePort.h"

#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSEventListener.h"
#include "SchemaBindings.h"
#include "StructuredSerializeBinding.h"
#include "StructuredSerializeOptions.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace WebCore {

using namespace JSC;

bool JSMessagePortOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSMessagePort>(handle.slot()->asCell());
    auto& wrapped = wrapper->wrapped();
    if (wrapped.hasPendingActivity()) {
        if (reason) [[unlikely]]
            *reason = "ActiveDOMObject with pending activity"_s;
        return true;
    }
    if (reason) [[unlikely]]
        *reason = "Reachable from MessagePort"_s;
    return visitor.containsOpaqueRoot(&wrapped) || visitor.containsOpaqueRoot(static_cast<EventTarget*>(&wrapped));
}

void JSMessagePortOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSMessagePort*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

using namespace JSC;
using namespace WebCore;

namespace Bindgen {
namespace Cpp {

static std::optional<JSValue> messagePortEventHandler(CppEngineCallContext<JSMessagePort>& ctx, const AtomString& eventType)
{
    return eventHandlerAttribute(ctx.wrapped(), eventType, worldForDOMObject(ctx.wrapper));
}

static void setMessagePortEventHandler(CppEngineCallContext<JSMessagePort>& ctx, const AtomString& eventType, const std::optional<JSValue>& value)
{
    setEventHandlerAttribute<JSEventListener>(ctx.globalObject, ctx.wrapped(), eventType, value, ctx.wrapper);
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_MessagePort_getter_onmessage(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_getter_onmessage_Arguments&)
{
    return messagePortEventHandler(ctx, eventNames().messageEvent);
}

void bunBindgenCpp_WebCoreEvents_MessagePort_setter_onmessage(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_setter_onmessage_Arguments& args)
{
    setMessagePortEventHandler(ctx, eventNames().messageEvent, args.value);
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_MessagePort_getter_onmessageerror(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_getter_onmessageerror_Arguments&)
{
    return messagePortEventHandler(ctx, eventNames().messageerrorEvent);
}

void bunBindgenCpp_WebCoreEvents_MessagePort_setter_onmessageerror(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_setter_onmessageerror_Arguments& args)
{
    setMessagePortEventHandler(ctx, eventNames().messageerrorEvent, args.value);
}

void bunBindgenCpp_WebCoreEvents_MessagePort_method_postMessage(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_method_postMessage_Arguments& args)
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

void bunBindgenCpp_WebCoreEvents_MessagePort_method_start(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_method_start_Arguments&)
{
    ctx.wrapped().start();
}

void bunBindgenCpp_WebCoreEvents_MessagePort_method_close(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_method_close_Arguments&)
{
    ctx.wrapped().close();
}

void bunBindgenCpp_WebCoreEvents_MessagePort_method_ref(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_method_ref_Arguments&)
{
    ctx.wrapped().jsRef();
}

void bunBindgenCpp_WebCoreEvents_MessagePort_method_unref(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_method_unref_Arguments&)
{
    ctx.wrapped().jsUnref();
}

bool bunBindgenCpp_WebCoreEvents_MessagePort_method_hasRef(
    CppEngineCallContext<JSMessagePort>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessagePort_method_hasRef_Arguments&)
{
    return ctx.wrapped().jsHasRef();
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
