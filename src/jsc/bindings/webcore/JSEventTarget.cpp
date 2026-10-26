#include "config.h"
#include "JSEventTarget.h"

#include "AddEventListenerOptions.h"
#include "BunProcess.h"
#include "DOMWrapperWorld.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSEvent.h"
#include "JSEventListener.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>

namespace WebCore {

using namespace JSC;

bool JSEventTargetOwner::isReachableFromOpaqueRoots(
    JSC::Handle<JSC::Unknown> handle,
    void*,
    AbstractSlotVisitor& visitor,
    ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSEventTarget>(handle.slot()->asCell());
    if (wrapper->wrapped().isFiringEventListeners()) {
        if (reason) [[unlikely]]
            *reason = "EventTarget firing event listeners"_s;
        return true;
    }
    if (reason) [[unlikely]]
        *reason = "Reachable from Event"_s;
    return visitor.containsOpaqueRoot(&wrapper->wrapped());
}

void JSEventTargetOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSEventTarget*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

template<typename Visitor>
void BunBindgen_WebCoreEvents_EventTarget::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().visitJSEventListeners(visitor);
}

template void BunBindgen_WebCoreEvents_EventTarget::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_EventTarget::visitAdditionalChildren(JSC::SlotVisitor&);

} // namespace Bun

WTF::RefPtr<WebCore::EventListener> Bun::Bindgen::createEventListener(
    JSC::JSGlobalObject& globalObject,
    JSC::JSObject* listener,
    JSC::JSObject& receiver)
{
    if (!listener)
        return nullptr;
    return WebCore::JSEventListener::create(*listener, receiver, false, WebCore::currentWorld(globalObject));
}

WebCore::EventTarget::AddEventListenerOptionsOrBoolean Bun::Bindgen::materializeEventListenerOptions(
    const AddEventListenerOptionsInput& input)
{
    if (input.is_capture())
        return input.capture();
    RELEASE_ASSERT(input.is_options());
    const auto& options = input.options();
    return WebCore::AddEventListenerOptions {
        options.capture.value_or(false),
        options.passive,
        options.once.value_or(false),
        options.signal.value_or(std::nullopt).value_or(nullptr),
    };
}

WebCore::EventTarget::EventListenerOptionsOrBoolean Bun::Bindgen::materializeEventListenerOptions(
    const RemoveEventListenerOptionsInput& input)
{
    if (input.is_capture())
        return input.capture();
    RELEASE_ASSERT(input.is_options());
    return WebCore::EventListenerOptions { input.options().capture.value_or(false) };
}

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

JSEventTarget* bunBindgenCpp_WebCoreEvents_EventTarget_construct(
    CppEngineConstructContext<JSEventTarget>& context,
    const BunBindgenCpp_WebCoreEvents_EventTarget_construct_Arguments&)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* scriptContext = global->scriptExecutionContext();
    if (!scriptContext) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(context.globalObject, scope, "EventTarget"_s);
        return nullptr;
    }

    auto target = EventTarget::create(*scriptContext);
    auto* native = target.ptr();
    auto* wrapper = JSEventTarget::create(context.structure, global, WTF::move(target));
    cacheWrapper(global->world(), native, wrapper);
    return wrapper;
}

template<typename Listener>
static void emitNullishListenerWarning(
    CppEngineCallContext<JSEventTarget>& context,
    const Listener& listener,
    const WTF::String& type)
{
    if (listener.is_listener())
        return;

    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto message = listener.is_null_value()
        ? "addEventListener called with null listener, which has no effect."_s
        : "addEventListener called with undefined listener, which has no effect."_s;
    auto* error = ErrorInstance::create(
        vm,
        globalObject.errorStructure(ErrorType::Error),
        message,
        JSValue(),
        nullptr,
        RuntimeType::TypeNothing,
        ErrorType::Error);
    RETURN_IF_EXCEPTION(scope, void());
    auto* name = JSC::jsString(vm, WTF::String("AddEventListenerArgumentTypeWarning"_s));
    RETURN_IF_EXCEPTION(scope, void());
    error->putDirect(vm, vm.propertyNames->name, name);
    RETURN_IF_EXCEPTION(scope, void());
    error->putDirect(vm, vm.propertyNames->target, &context.wrapper);
    RETURN_IF_EXCEPTION(scope, void());
    auto* typeValue = jsString(vm, type);
    RETURN_IF_EXCEPTION(scope, void());
    error->putDirect(vm, vm.propertyNames->type, typeValue);
    RETURN_IF_EXCEPTION(scope, void());
    Process::emitWarningErrorInstance(&globalObject, error);
    RETURN_IF_EXCEPTION(scope, void());
}

void bunBindgenCpp_WebCoreEvents_EventTarget_method_addEventListener(
    CppEngineCallContext<JSEventTarget>& context,
    const BunBindgenCpp_WebCoreEvents_EventTarget_method_addEventListener_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto listener = createEventListener(context.globalObject, args.listener, context.wrapper);
    auto options = args.options
        ? materializeEventListenerOptions(*args.options)
        : EventTarget::AddEventListenerOptionsOrBoolean { false };
    emitNullishListenerWarning(context, args.listener, args.type);
    RETURN_IF_EXCEPTION(scope, void());
    context.wrapped().addEventListenerForBindings(context.globalObject, AtomString { args.type }, WTF::move(listener), WTF::move(options));
    RETURN_IF_EXCEPTION(scope, void());
    context.globalObject.vm().writeBarrier(&context.wrapper, eventListenerValue(args.listener));
}

void bunBindgenCpp_WebCoreEvents_EventTarget_method_removeEventListener(
    CppEngineCallContext<JSEventTarget>& context,
    const BunBindgenCpp_WebCoreEvents_EventTarget_method_removeEventListener_Arguments& args)
{
    auto listener = createEventListener(context.globalObject, args.listener, context.wrapper);
    auto options = args.options
        ? materializeEventListenerOptions(*args.options)
        : EventTarget::EventListenerOptionsOrBoolean { false };
    context.wrapped().removeEventListenerForBindings(AtomString { args.type }, WTF::move(listener), WTF::move(options));
    context.globalObject.vm().writeBarrier(&context.wrapper, eventListenerValue(args.listener));
}

bool bunBindgenCpp_WebCoreEvents_EventTarget_method_dispatchEvent(
    CppEngineCallContext<JSEventTarget>& context,
    const BunBindgenCpp_WebCoreEvents_EventTarget_method_dispatchEvent_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = context.wrapped().dispatchEventForBindings(*args.event);
    if (result.hasException()) {
        propagateException(context.globalObject, scope, result.releaseException());
        return false;
    }
    return result.releaseReturnValue();
}

} // namespace Bun::Bindgen::Cpp

std::optional<size_t> Bun::Bindgen::Cpp::bunBindgenCpp_EventTarget_getEventListenersCount(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_EventTarget_getEventListenersCount_Arguments& args)
{
    if (!args.target)
        return std::nullopt;
    auto* target = dynamicDowncast<WebCore::JSEventTarget>(*args.target);
    RELEASE_ASSERT(target);
    return target->wrapped().eventListeners(WTF::makeAtomString(args.event_type)).size();
}
