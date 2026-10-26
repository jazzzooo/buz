#include "config.h"
#include "JSMessageEvent.h"

#include "DOMWrapperWorld.h"
#include "JSBufferSource.h"
#include "JSDOMExceptionHandling.h"
#include "JSDOMWrapperCache.h"
#include "JSBuffer.h"
#include "JSMessagePort.h"
#include "MessageEvent.h"
#include "SchemaBindings.h"
#include "SerializedScriptValue.h"
#include "ZigGlobalObject.h"
#include "blob.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <JavaScriptCore/SlotVisitorMacros.h>

namespace Bun {

using namespace JSC;
using namespace WebCore;

template<typename Visitor>
void BunBindgen_WebCoreEvents_MessageEvent::visitAdditionalChildren(Visitor& visitor)
{
    wrapped().jsData().visit(visitor);
    wrapped().visitPorts(visitor);
}

template void BunBindgen_WebCoreEvents_MessageEvent::visitAdditionalChildren(JSC::AbstractSlotVisitor&);
template void BunBindgen_WebCoreEvents_MessageEvent::visitAdditionalChildren(JSC::SlotVisitor&);

namespace Bindgen {
namespace Cpp {

JSMessageEvent* bunBindgenCpp_WebCoreEvents_MessageEvent_construct(
    CppEngineConstructContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_construct_Arguments& args)
{
    auto* global = &ctx.globalObject;
    auto* zigGlobal = defaultGlobalObject(global);
    auto scope = DECLARE_THROW_SCOPE(global->vm());

    MessageEvent::Init init;
    if (const auto& dict = args.eventInitDict) {
        init.bubbles = dict->bubbles;
        init.cancelable = dict->cancelable;
        init.composed = dict->composed;
        init.data = dict->data;
        init.lastEventId = dict->last_event_id;
        init.origin = dict->origin;
        if (dict->ports && *dict->ports) {
            if (!init.ports.tryReserveInitialCapacity((**dict->ports).size())) {
                throwOutOfMemoryError(global, scope);
                return nullptr;
            }
            for (auto* port : **dict->ports)
                init.ports.unsafeAppendWithoutCapacityCheck(port);
        }
        if (dict->source && *dict->source)
            init.source = **dict->source;
    } else {
        init.lastEventId = emptyString();
        init.origin = emptyString();
    }

    auto impl = MessageEvent::create(AtomString { args.type }, WTF::move(init));
    auto* implPtr = impl.ptr();
    auto* wrapper = JSMessageEvent::create(ctx.structure, zigGlobal, WTF::move(impl));
    cacheWrapper(zigGlobal->world(), implPtr, wrapper);
    ctx.globalObject.vm().writeBarrier(wrapper);
    return wrapper;
}

WTF::String bunBindgenCpp_WebCoreEvents_MessageEvent_getter_origin(
    CppEngineCallContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_getter_origin_Arguments&)
{
    return ctx.wrapped().origin();
}

WTF::String bunBindgenCpp_WebCoreEvents_MessageEvent_getter_lastEventId(
    CppEngineCallContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_getter_lastEventId_Arguments&)
{
    return ctx.wrapped().lastEventId();
}

std::optional<JSValue> bunBindgenCpp_WebCoreEvents_MessageEvent_getter_source(
    CppEngineCallContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_getter_source_Arguments&)
{
    auto* source = ctx.wrapped().source().get();
    if (!source)
        return std::nullopt;
    return toJS(&ctx.globalObject, defaultGlobalObject(&ctx.globalObject), *source);
}

MessageEventDataResult bunBindgenCpp_WebCoreEvents_MessageEvent_getter_data(
    CppEngineCallContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_getter_data_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(global->vm());
    auto& event = ctx.wrapped();
    auto* zigGlobal = defaultGlobalObject(global);
    MessageEventDataResult result;
    std::visit(
        WTF::makeVisitor(
            [&](MessageEvent::JSValueTag) { result.set_stored(event.jsData().get()); },
            [&](const Ref<SerializedScriptValue>& data) {
                result.set_deserialized(data->deserialize(*global, zigGlobal, event.ports(), SerializationErrorMode::NonThrowing));
            },
            [&](const String& data) { result.set_text(data); },
            [&](const Ref<Blob>& data) { result.set_blob(WebCore::toJS(global, zigGlobal, data.get())); },
            [&](const Ref<ArrayBuffer>& data) { result.set_array_buffer(WebCore::toJS(global, zigGlobal, data.get())); },
            [&](const MessageEvent::NodeBufferData& data) { result.set_node_buffer(createBuffer(global, data.buffer.copyRef())); },
            [&](const MessageEvent::JSONData& data) {
                auto value = JSC::JSONParse(global, data.text);
                result.set_deserialized(value ? value : jsUndefined());
            }),
        event.data());
    RETURN_IF_EXCEPTION(throwScope, {});
    return result;
}

CppResultSequence<JSValue> bunBindgenCpp_WebCoreEvents_MessageEvent_getter_ports(
    CppEngineCallContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_getter_ports_Arguments&)
{
    auto* global = &ctx.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(global->vm());
    auto* domGlobal = defaultGlobalObject(global);
    CppResultSequence<JSValue> result;
    if (!result.reserveCapacity(ctx.results(), ctx.wrapped().ports().size()))
        return {};
    for (const auto& port : ctx.wrapped().ports()) {
        RELEASE_ASSERT(port);
        auto value = toJS(global, domGlobal, *port);
        RETURN_IF_EXCEPTION(throwScope, {});
        if (!result.append(ctx.results(), value))
            return {};
    }
    return result;
}

void bunBindgenCpp_WebCoreEvents_MessageEvent_method_initMessageEvent(
    CppEngineCallContext<JSMessageEvent>& ctx,
    const BunBindgenCpp_WebCoreEvents_MessageEvent_method_initMessageEvent_Arguments& args)
{
    if (ctx.wrapped().isBeingDispatched())
        return;
    auto scope = DECLARE_THROW_SCOPE(ctx.globalObject.vm());
    RefPtr<MessagePort> source = args.source.value_or(nullptr);
    Vector<RefPtr<MessagePort>> ports;
    if (args.ports) {
        if (!ports.tryReserveInitialCapacity(args.ports->size())) {
            throwOutOfMemoryError(&ctx.globalObject, scope);
            return;
        }
        for (auto* port : *args.ports)
            ports.unsafeAppendWithoutCapacityCheck(port);
    }
    ctx.wrapped().initMessageEvent(ctx.globalObject.vm(), AtomString { args.type }, args.bubbles, args.cancelable, args.data, args.originArg, args.lastEventId, WTF::move(source), WTF::move(ports));
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
