#include "config.h"
#include "JSEvent.h"

#include "DOMWrapperWorld.h"
#include "JSDOMWrapperCache.h"
#include "JSEventTarget.h"
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <limits>

namespace WebCore {

using namespace JSC;

bool JSEventOwner::isReachableFromOpaqueRoots(
    JSC::Handle<JSC::Unknown>,
    void*,
    AbstractSlotVisitor&,
    ASCIILiteral*)
{
    return false;
}

void JSEventOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSEvent*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun {

template<typename Visitor>
void BunBindgen_WebCoreEvents_Event::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().visitTargets(visitor);
}

template void BunBindgen_WebCoreEvents_Event::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_Event::visitAdditionalChildren(JSC::SlotVisitor&);

} // namespace Bun

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

static std::optional<JSValue> eventTargetToJS(CppEngineCallContext<JSEvent>& context, EventTarget* target)
{
    if (!target)
        return std::nullopt;
    return toJS(&context.globalObject, defaultGlobalObject(&context.globalObject), target);
}

JSEvent* bunBindgenCpp_WebCoreEvents_Event_construct(
    CppEngineConstructContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_construct_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    WebCore::EventInit init;
    if (const auto& dictionary = args.eventInitDict) {
        init.bubbles = dictionary->bubbles;
        init.cancelable = dictionary->cancelable;
        init.composed = dictionary->composed;
    }

    auto impl = Event::tryCreate(AtomString { args.type }, init);
    if (!impl) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return nullptr;
    }
    auto* implPtr = impl.get();
    auto* global = defaultGlobalObject(&context.globalObject);
    auto* wrapper = JSEvent::create(context.structure, global, impl.releaseNonNull());
    cacheWrapper(global->world(), implPtr, wrapper);
    return wrapper;
}

WTF::String bunBindgenCpp_WebCoreEvents_Event_getter_type(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_type_Arguments&)
{
    return context.wrapped().type().string();
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_Event_getter_target(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_target_Arguments&)
{
    return eventTargetToJS(context, context.wrapped().target());
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_Event_getter_currentTarget(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_currentTarget_Arguments&)
{
    return eventTargetToJS(context, context.wrapped().currentTarget());
}

uint16_t bunBindgenCpp_WebCoreEvents_Event_getter_eventPhase(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_eventPhase_Arguments&)
{
    return context.wrapped().eventPhase();
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_cancelBubble(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_cancelBubble_Arguments&)
{
    return context.wrapped().cancelBubble();
}

void bunBindgenCpp_WebCoreEvents_Event_setter_cancelBubble(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_setter_cancelBubble_Arguments& args)
{
    context.wrapped().setCancelBubble(args.value);
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_bubbles(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_bubbles_Arguments&)
{
    return context.wrapped().bubbles();
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_cancelable(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_cancelable_Arguments&)
{
    return context.wrapped().cancelable();
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_defaultPrevented(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_defaultPrevented_Arguments&)
{
    return context.wrapped().defaultPrevented();
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_composed(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_composed_Arguments&)
{
    return context.wrapped().composed();
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_isTrusted(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_isTrusted_Arguments&)
{
    return context.wrapped().isTrusted();
}

std::optional<double> bunBindgenCpp_WebCoreEvents_Event_getter_timeStamp(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_timeStamp_Arguments&)
{
    auto* scriptContext = context.wrapper.globalObject()->scriptExecutionContext();
    if (!scriptContext)
        return std::nullopt;
    return context.wrapped().timeStampForBindings(*scriptContext);
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_Event_getter_srcElement(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_srcElement_Arguments&)
{
    return eventTargetToJS(context, context.wrapped().target());
}

bool bunBindgenCpp_WebCoreEvents_Event_getter_returnValue(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_getter_returnValue_Arguments&)
{
    return context.wrapped().legacyReturnValue();
}

void bunBindgenCpp_WebCoreEvents_Event_setter_returnValue(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_setter_returnValue_Arguments& args)
{
    context.wrapped().setLegacyReturnValue(args.value);
}

CppResultSequence<JSValue> bunBindgenCpp_WebCoreEvents_Event_method_composedPath(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_method_composedPath_Arguments&)
{
    auto& global = context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto path = context.wrapped().composedPath();
    CppResultSequence<JSValue> result;
    if (!result.reserveCapacity(context.results(), path.size()))
        return {};
    auto* domGlobal = defaultGlobalObject(&global);
    for (auto& target : path) {
        auto value = toJS(&global, domGlobal, target.get());
        RETURN_IF_EXCEPTION(scope, result);
        if (!result.append(context.results(), value))
            return result;
    }
    return result;
}

void bunBindgenCpp_WebCoreEvents_Event_method_stopPropagation(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_method_stopPropagation_Arguments&)
{
    context.wrapped().stopPropagation();
}

void bunBindgenCpp_WebCoreEvents_Event_method_stopImmediatePropagation(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_method_stopImmediatePropagation_Arguments&)
{
    context.wrapped().stopImmediatePropagation();
}

void bunBindgenCpp_WebCoreEvents_Event_method_preventDefault(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_method_preventDefault_Arguments&)
{
    context.wrapped().preventDefault();
}

void bunBindgenCpp_WebCoreEvents_Event_method_initEvent(
    CppEngineCallContext<JSEvent>& context,
    const BunBindgenCpp_WebCoreEvents_Event_method_initEvent_Arguments& args)
{
    context.wrapped().initEvent(AtomString { args.type }, args.bubbles, args.cancelable);
}

} // namespace Bun::Bindgen::Cpp
