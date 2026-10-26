#include "config.h"
#include "JSEventEmitter.h"

#include "DOMWrapperWorld.h"
#include "EventTargetOwner.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "SchemaBindings.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/ArrayConstructor.h>
#include <JavaScriptCore/JSCInlines.h>

namespace WebCore {

using namespace JSC;

bool JSEventEmitterOwner::isReachableFromOpaqueRoots(
    JSC::Handle<JSC::Unknown> handle,
    void*,
    AbstractSlotVisitor& visitor,
    ASCIILiteral* reason)
{
    auto* wrapper = uncheckedDowncast<JSEventEmitter>(handle.slot()->asCell());
    if (wrapper->wrapped().isFiringEventListeners()) {
        if (reason) [[unlikely]]
            *reason = "EventEmitter firing event listeners"_s;
        return true;
    }
    UNUSED_PARAM(visitor);
    return false;
}

void JSEventEmitterOwner::finalize(JSC::Handle<JSC::Unknown> handle, void* context)
{
    auto* wrapper = static_cast<JSEventEmitter*>(handle.slot()->asCell());
    auto& world = *static_cast<DOMWrapperWorld*>(context);
    uncacheWrapper(world, &wrapper->wrapped(), wrapper);
}

} // namespace WebCore

namespace Bun::Bindgen::Cpp {

using namespace JSC;
using namespace WebCore;

static JSEventEmitter* createEventEmitter(JSGlobalObject& lexicalGlobalObject, Structure* structure)
{
    auto* global = defaultGlobalObject(&lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject.vm());
    auto* scriptContext = global->scriptExecutionContext();
    if (!scriptContext) [[unlikely]] {
        throwConstructorScriptExecutionContextUnavailableError(lexicalGlobalObject, scope, "EventEmitter"_s);
        return nullptr;
    }

    auto emitter = EventEmitter::create(*scriptContext);
    auto* native = emitter.ptr();
    auto* wrapper = JSEventEmitter::create(structure, global, WTF::move(emitter));
    cacheWrapper(global->world(), native, wrapper);
    return wrapper;
}

JSEventEmitter* bunBindgenCpp_WebCoreEvents_EventEmitter_construct(
    CppEngineConstructContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_construct_Arguments&)
{
    return createEventEmitter(context.globalObject, context.structure);
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_call(
    CppCallContext& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_call_Arguments&)
{
    auto* global = defaultGlobalObject(&context.globalObject);
    return createEventEmitter(context.globalObject, global->BunBindgen_WebCoreEvents_EventEmitterStructure());
}

static Identifier eventEmitterIdentifier(JSGlobalObject& globalObject, const PropertyKeyResult& key)
{
    if (key.is_symbol())
        return Identifier::fromUid(asSymbol(key.symbol())->privateName());
    RELEASE_ASSERT(key.is_string());
    return Identifier::fromString(globalObject.vm(), key.string());
}

template<typename Arguments>
static JSValue addEventEmitterListener(
    CppEngineCallContext<JSEventEmitter>& context,
    const Arguments& args,
    bool once,
    bool prepend)
{
    auto& globalObject = context.globalObject;
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    RELEASE_ASSERT(args.key);
    const auto* key = args.key->convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!key)
        return {};
    auto identifier = eventEmitterIdentifier(globalObject, *key);
    auto listenerValue = eventListenerValue(args.listener);

    MarkedArgumentBuffer newListenerArguments;
    args.event.appendTo(newListenerArguments);
    newListenerArguments.append(listenerValue);
    if (newListenerArguments.hasOverflowed()) {
        throwOutOfMemoryError(&globalObject, scope);
        return {};
    }
    context.wrapped().emitForBindings(Identifier::fromString(vm, "newListener"_s), newListenerArguments);
    RETURN_IF_EXCEPTION(scope, {});

    auto listener = createEventListener(globalObject, args.listener, context.wrapper);
    context.wrapped().addListenerForBindings(identifier, WTF::move(listener), once, prepend);
    RETURN_IF_EXCEPTION(scope, {});

    vm.writeBarrier(&context.wrapper, listenerValue);
    context.wrapped().setThisObject(&context.wrapper);
    return &context.wrapper;
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_method_addListener(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_addListener_Arguments& args)
{
    return addEventEmitterListener(context, args, false, false);
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_method_once(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_once_Arguments& args)
{
    return addEventEmitterListener(context, args, true, false);
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_method_prependListener(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_prependListener_Arguments& args)
{
    return addEventEmitterListener(context, args, false, true);
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_method_prependOnceListener(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_prependOnceListener_Arguments& args)
{
    return addEventEmitterListener(context, args, true, true);
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_method_removeListener(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_removeListener_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const auto* key = args.event.convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!key)
        return {};
    auto identifier = eventEmitterIdentifier(context.globalObject, *key);
    if (!args.listener) {
        context.wrapped().removeAllListeners(identifier);
        return &context.wrapper;
    }

    auto listener = createEventListener(context.globalObject, *args.listener, context.wrapper);
    context.wrapped().removeListenerForBindings(identifier, WTF::move(listener));
    RETURN_IF_EXCEPTION(scope, {});
    context.globalObject.vm().writeBarrier(&context.wrapper, eventListenerValue(*args.listener));
    context.wrapped().setThisObject(&context.wrapper);
    return &context.wrapper;
}

JSValue bunBindgenCpp_WebCoreEvents_EventEmitter_method_removeAllListeners(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_removeAllListeners_Arguments& args)
{
    if (!args.event) {
        context.wrapped().removeAllListeners();
        return &context.wrapper;
    }

    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto eventKey = eventEmitterIdentifier(context.globalObject, *args.event);
    RETURN_IF_EXCEPTION(scope, {});
    context.wrapped().removeAllListenersForBindings(eventKey);
    context.wrapped().setThisObject(&context.wrapper);
    return &context.wrapper;
}

bool bunBindgenCpp_WebCoreEvents_EventEmitter_method_emit(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_emit_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    MarkedArgumentBuffer values;
    for (auto value : args.values)
        value.appendTo(values);
    if (values.hasOverflowed()) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return false;
    }
    auto eventKey = eventEmitterIdentifier(context.globalObject, args.event);
    RETURN_IF_EXCEPTION(scope, false);
    RELEASE_AND_RETURN(scope, context.wrapped().emitForBindings(eventKey, values));
}

CppResultSequence<PropertyKeyResult> bunBindgenCpp_WebCoreEvents_EventEmitter_method_eventNames(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_eventNames_Arguments&)
{
    auto& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    CppResultSequence<PropertyKeyResult> result;
    auto names = context.wrapped().getEventNames();
    if (!result.reserveCapacity(context.results(), names.size()))
        return {};
    for (auto& name : names) {
        PropertyKeyResult key;
        if (name.isSymbol() && !name.isPrivateName()) {
            auto symbol = identifierToSafePublicJSValue(vm, name);
            RETURN_IF_EXCEPTION(scope, result);
            key.set_symbol(symbol);
        } else {
            key.set_string(name.string());
        }
        if (!result.append(context.results(), WTF::move(key)))
            return result;
    }
    return result;
}

int32_t bunBindgenCpp_WebCoreEvents_EventEmitter_method_listenerCount(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_listenerCount_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto eventKey = eventEmitterIdentifier(context.globalObject, args.event);
    RETURN_IF_EXCEPTION(scope, 0);
    RELEASE_AND_RETURN(scope, context.wrapped().listenerCount(eventKey));
}

CppResultSequence<JSValue> bunBindgenCpp_WebCoreEvents_EventEmitter_method_listeners(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_listeners_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    CppResultSequence<JSValue> result;
    auto eventKey = eventEmitterIdentifier(context.globalObject, args.event);
    RETURN_IF_EXCEPTION(scope, result);
    auto listeners = context.wrapped().getListeners(eventKey);
    if (!listeners) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return {};
    }
    if (!result.reserveCapacity(context.results(), listeners->size()))
        return {};
    for (auto* listener : *listeners) {
        if (!result.append(context.results(), listener))
            return result;
    }
    return result;
}

void bunBindgenCpp_WebCoreEvents_EventEmitter_method_setMaxListeners(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_setMaxListeners_Arguments& args)
{
    if (args.maxListeners)
        context.wrapped().setMaxListeners(*args.maxListeners);
}

uint32_t bunBindgenCpp_WebCoreEvents_EventEmitter_method_getMaxListeners(
    CppEngineCallContext<JSEventEmitter>& context,
    const BunBindgenCpp_WebCoreEvents_EventEmitter_method_getMaxListeners_Arguments&)
{
    return context.wrapped().getMaxListeners();
}

} // namespace Bun::Bindgen::Cpp
