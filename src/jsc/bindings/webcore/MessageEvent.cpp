/*
 * Copyright (C) 2007 Henry Mason (hmason@mac.com)
 * Copyright (C) 2003-2018 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */
#include "root.h"
#include "config.h"
#include "MessageEvent.h"

// #include "Blob.h"
#include "EventNames.h"
#include "JSDOMWrapperCache.h"
#include "JSMessageEvent.h"
#include "WebCoreJSClientData.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/TZoneMallocInlines.h>
#include "blob.h"

namespace WebCore {

using namespace JSC;

WTF_MAKE_TZONE_ALLOCATED_IMPL(MessageEvent);

MessageEvent::MessageEvent()
    : Event(MessageEventInterfaceType)
{
}

inline MessageEvent::MessageEvent(const AtomString& type, Init&& initializer, IsTrusted isTrusted)
    : Event(MessageEventInterfaceType, type, initializer, isTrusted)
    , m_data(JSValueTag {})
    , m_origin(initializer.origin)
    , m_lastEventId(initializer.lastEventId)
    , m_source(WTF::move(initializer.source))
    , m_ports(WTF::move(initializer.ports))
    , m_jsData(initializer.data)
{
}

inline MessageEvent::MessageEvent(const AtomString& type, DataType&& data, const String& origin, const String& lastEventId, RefPtr<MessagePort>&& source, Vector<RefPtr<MessagePort>>&& ports)
    : Event(MessageEventInterfaceType, type, CanBubble::No, IsCancelable::No)
    , m_data(WTF::move(data))
    , m_origin(origin)
    , m_lastEventId(lastEventId)
    , m_source(WTF::move(source))
    , m_ports(WTF::move(ports))
{
}

Ref<MessageEvent> MessageEvent::create(const AtomString& type, DataType&& data, const String& origin, const String& lastEventId, RefPtr<MessagePort>&& source, Vector<RefPtr<MessagePort>>&& ports)
{
    return adoptRef(*new MessageEvent(type, WTF::move(data), origin, lastEventId, WTF::move(source), WTF::move(ports)));
}

Ref<MessageEvent> MessageEvent::create(DataType&& data, const String& origin, const String& lastEventId, RefPtr<MessagePort>&& source, Vector<RefPtr<MessagePort>>&& ports)
{
    return create(eventNames().messageEvent, WTF::move(data), origin, lastEventId, WTF::move(source), WTF::move(ports));
}

Ref<MessageEvent> MessageEvent::createForBindings()
{
    return adoptRef(*new MessageEvent);
}

Ref<MessageEvent> MessageEvent::create(const AtomString& type, Init&& initializer, IsTrusted isTrusted)
{
    return adoptRef(*new MessageEvent(type, WTF::move(initializer), isTrusted));
}

MessageEvent::~MessageEvent() = default;

auto MessageEvent::create(JSC::JSGlobalObject& globalObject, Ref<SerializedScriptValue>&& data, RefPtr<MessagePort>&& source, Vector<RefPtr<MessagePort>>&& ports) -> std::optional<MessageEventWithStrongData>
{
    return create(globalObject, WTF::move(data), {}, {}, WTF::move(source), WTF::move(ports));
}

auto MessageEvent::create(JSC::JSGlobalObject& globalObject, Ref<SerializedScriptValue>&& data, const String& origin, const String& lastEventId, RefPtr<MessagePort>&& source, Vector<RefPtr<MessagePort>>&& ports) -> std::optional<MessageEventWithStrongData>
{
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    bool didFail = false;

    auto deserialized = data->deserialize(globalObject, &globalObject, ports, SerializationErrorMode::NonThrowing, &didFail);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (didFail)
        deserialized = jsNull();

    auto& eventType = didFail ? eventNames().messageerrorEvent : eventNames().messageEvent;
    auto event = adoptRef(*new MessageEvent(eventType, WTF::move(data), origin, lastEventId, WTF::move(source), WTF::move(ports)));
    auto wrapperValue = toJS(&globalObject, uncheckedDowncast<JSDOMGlobalObject>(&globalObject), event.get());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    auto* wrapper = uncheckedDowncast<JSMessageEvent>(wrapperValue);
    wrapper->set_slot_data(vm, deserialized);

    return std::optional<MessageEventWithStrongData> { std::in_place, WTF::move(event), vm, wrapper };
}

void MessageEvent::initMessageEvent(JSC::VM& vm, const AtomString& type, bool canBubble, bool cancelable, Bun::Bindgen::CppAny data, const String& origin, const String& lastEventId, RefPtr<MessagePort>&& source, Vector<RefPtr<MessagePort>>&& ports)
{
    if (isBeingDispatched())
        return;

    initEvent(type, canBubble, cancelable);

    DataType replacedData { JSValueTag {} };
    {
        Locker locker { m_concurrentDataAccessLock };
        std::swap(m_data, replacedData);
        m_source.swap(source);
        m_ports.swap(ports);
    }
    m_jsData.set(data);
    m_origin = origin;
    m_lastEventId = lastEventId;
    auto* worlds = static_cast<JSVMClientData*>(vm.clientData)->wrapperWorlds();
    forEachCachedWrapper(worlds, *this, [&vm](JSC::JSObject* object) {
        auto* wrapper = uncheckedDowncast<JSMessageEvent>(object);
        wrapper->clear_slot_data();
        wrapper->clear_slot_ports();
        vm.writeBarrier(wrapper);
    });
}

template<typename Visitor>
void MessageEvent::visitPorts(Visitor& visitor) const
{
    Locker locker { m_concurrentDataAccessLock };
    if (m_source)
        visitor.addOpaqueRoot(m_source.get());
    for (auto& port : m_ports) {
        if (port)
            visitor.addOpaqueRoot(port.get());
    }
}

template void MessageEvent::visitPorts(JSC::AbstractSlotVisitor&) const;
template void MessageEvent::visitPorts(JSC::SlotVisitor&) const;

size_t MessageEvent::memoryCost() const
{
    Locker locker { m_concurrentDataAccessLock };
    return std::visit(
        WTF::makeVisitor(
            [](JSValueTag) -> size_t { return 0; },
            [](const Ref<SerializedScriptValue>& data) -> size_t { return data->memoryCost(); },
            [](const String& string) -> size_t { return string.sizeInBytes(); },
            [](const Ref<Blob>& blob) -> size_t { return blob->memoryCost(); },
            [](const Ref<ArrayBuffer>& buffer) -> size_t { return buffer->byteLength(); },
            [](const NodeBufferData& data) -> size_t { return data.buffer->byteLength(); },
            [](const JSONData& data) -> size_t { return data.text.sizeInBytes(); }),
        m_data);
}

} // namespace WebCore
