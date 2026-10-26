#include "config.h"
#include "JSBroadcastChannel.h"

#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSEventListener.h"
#include "ScriptExecutionContext.h"
#include "WebCoreJSClientData.h"
#include "ZigGlobalObject.h"
#include "ErrorCode.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyNameArray.h>

namespace WebCore {

using namespace JSC;

bool JSBroadcastChannelOwner::isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown> handle, void*, AbstractSlotVisitor& visitor, ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSBroadcastChannel>(handle.slot()->asCell());
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

void JSBroadcastChannelOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSBroadcastChannel*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

JSBroadcastChannel* bunBindgenCpp_WebCoreEvents_BroadcastChannel_construct(
    CppEngineConstructContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(global);
    auto* context = zigGlobal->scriptExecutionContext();
    if (!context) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(*global, scope, "BroadcastChannel"_s);
        return nullptr;
    }
    auto impl = BroadcastChannel::create(*context, args.name);
    auto* implPtr = impl.ptr();
    auto* wrapper = JSBroadcastChannel::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    return wrapper;
}

WTF::String bunBindgenCpp_WebCoreEvents_BroadcastChannel_getter_name(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_getter_name_Arguments&)
{
    return ctx.wrapped().name();
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_BroadcastChannel_getter_onmessage(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_getter_onmessage_Arguments&)
{
    return eventHandlerAttribute(ctx.wrapped(), eventNames().messageEvent, worldForDOMObject(ctx.wrapper));
}

void bunBindgenCpp_WebCoreEvents_BroadcastChannel_setter_onmessage(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_setter_onmessage_Arguments& args)
{
    setEventHandlerAttribute<JSEventListener>(ctx.globalObject, ctx.wrapped(), eventNames().messageEvent, args.value, ctx.wrapper);
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_BroadcastChannel_getter_onmessageerror(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_getter_onmessageerror_Arguments&)
{
    return eventHandlerAttribute(ctx.wrapped(), eventNames().messageerrorEvent, worldForDOMObject(ctx.wrapper));
}

void bunBindgenCpp_WebCoreEvents_BroadcastChannel_setter_onmessageerror(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_setter_onmessageerror_Arguments& args)
{
    setEventHandlerAttribute<JSEventListener>(ctx.globalObject, ctx.wrapped(), eventNames().messageerrorEvent, args.value, ctx.wrapper);
}

void bunBindgenCpp_WebCoreEvents_BroadcastChannel_method_postMessage(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_method_postMessage_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    auto result = ctx.wrapped().postMessage(*global, args.message);
    RETURN_IF_EXCEPTION(scope, void());
    if (result.hasException()) [[unlikely]]
        propagateException(*global, scope, result.releaseException());
}

void bunBindgenCpp_WebCoreEvents_BroadcastChannel_method_close(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_method_close_Arguments&)
{
    ctx.wrapped().jsUnref(&ctx.globalObject);
    ctx.wrapped().close();
}

void bunBindgenCpp_WebCoreEvents_BroadcastChannel_method_ref(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_method_ref_Arguments&)
{
    ctx.wrapped().jsRef(&ctx.globalObject);
}

JSValue bunBindgenCpp_WebCoreEvents_BroadcastChannel_method_unref(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_method_unref_Arguments&)
{
    ctx.wrapped().jsUnref(&ctx.globalObject);
    return &ctx.wrapper;
}

WTF::String bunBindgenCpp_WebCoreEvents_BroadcastChannel_method_inspectCustom(
    CppEngineCallContext<JSBroadcastChannel>& ctx,
    const BunBindgenCpp_WebCoreEvents_BroadcastChannel_method_inspectCustom_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(global);
    auto& channel = ctx.wrapped();

    if (args.depth && *args.depth < 0)
        return "BroadcastChannel"_s;

    JSValue depthValue = args.depth ? jsNumber(*args.depth - 1) : jsUndefined();
    JSObject* options = args.options.getObject();
    RELEASE_ASSERT(options);
    JSC::PropertyNameArrayBuilder names(vm, JSC::PropertyNameMode::StringsAndSymbols, JSC::PrivateSymbolMode::Exclude);
    options->getPropertyNames(global, names, JSC::DontEnumPropertiesMode::Exclude);
    RETURN_IF_EXCEPTION(scope, {});
    JSObject* newOptions = JSC::constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, {});
    for (size_t index = 0; index < names.size(); ++index) {
        auto name = names[index];
        JSC::JSValue property = options->get(global, name);
        RETURN_IF_EXCEPTION(scope, {});
        newOptions->putDirect(vm, name, property, 0);
    }

    PutPropertySlot slot(newOptions);
    newOptions->put(newOptions, global, Identifier::fromString(vm, "depth"_s), depthValue, slot);
    RETURN_IF_EXCEPTION(scope, {});

    JSObject* inputObj = constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, {});
    auto* name = jsString(vm, channel.name());
    RETURN_IF_EXCEPTION(scope, {});
    inputObj->putDirect(vm, vm.propertyNames->name, name, 0);
    inputObj->putDirect(vm, Identifier::fromString(vm, "active"_s), jsBoolean(!channel.isClosed()), 0);

    JSFunction* utilInspect = zigGlobal->utilInspectFunction();
    RETURN_IF_EXCEPTION(scope, {});
    auto callData = JSC::getCallData(utilInspect);
    MarkedArgumentBuffer arguments;
    arguments.append(inputObj);
    arguments.append(newOptions);

    auto inspectResult = JSC::profiledCall(zigGlobal, ProfilingReason::API, utilInspect, callData, inputObj, arguments);
    RETURN_IF_EXCEPTION(scope, {});

    auto inspectString = inspectResult.toWTFString(global);
    RETURN_IF_EXCEPTION(scope, {});

    return makeString("BroadcastChannel "_s, inspectString);
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
