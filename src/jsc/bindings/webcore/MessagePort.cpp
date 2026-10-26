/*
 * Copyright (C) 2008 Apple Inc. All Rights Reserved.
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

#include "config.h"
#include "MessagePort.h"

#include "BunClientData.h"
#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "MessageEvent.h"
#include "MessagePortPipe.h"
#include "NativeEventLoopTarget.h"
#include "MessageWithMessagePorts.h"
#include "StructuredSerializeOptions.h"
#include "WebCoreOpaqueRoot.h"
#include "SchemaBindings.h"
#include <algorithm>
#include <functional>

namespace WebCore {

class MessagePortWakeup final : public MessagePortPipe::Wakeup {
public:
    static RefPtr<MessagePortWakeup> tryCreate()
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(MessagePortWakeup)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) MessagePortWakeup);
    }

    ~MessagePortWakeup()
    {
        if (m_signal)
            Bun::Bindgen::Engine::releaseNativeEventLoopSignal(m_signal);
    }

    void setSignal(Bun::NativeEventLoopSignal* signal)
    {
        ASSERT(!m_signal);
        m_signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_retainNativeEventSignal(signal);
    }

    void notify() const noexcept final
    {
        Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_notifyNativeEventSignal(m_signal);
    }

private:
    Bun::NativeEventLoopSignal* m_signal { nullptr };
};

class MessagePort::DeliveryTarget final : public Bun::NativeEventLoopTarget, public ScriptExecutionContext::NativeLifetime {
public:
    static RefPtr<DeliveryTarget> tryCreate(MessagePort& port)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(DeliveryTarget)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) DeliveryTarget(port));
    }

    void run(JSC::JSGlobalObject*) noexcept final
    {
        if (!m_port)
            return;
        Ref port { *m_port };
        auto* context = this->context();
        if (!context || !context->globalObject())
            return;
        if (port->m_deliveryState.load(std::memory_order_relaxed) == DeliveryState::ClosePending) {
            port->dispatchCloseEvent(*context);
            return;
        }
        auto* globalObject = defaultGlobalObject(context->globalObject());
        if (!port->m_started && !(port->m_hasCloseEventListener.load(std::memory_order_relaxed) && !port->m_pipe->isOtherSideOpen(port->m_side))) {
            if (!port->m_pipe->isOtherSideOpen(port->m_side) && !MessagePortPipe::queuedCount(port->m_pipe->state(port->m_side)))
                port->close();
            return;
        }
        size_t limit = std::max<uint64_t>(MessagePortPipe::queuedCount(port->m_pipe->state(port->m_side)), 1000);
        while (m_port == port.ptr() && port->isEntangled()) {
            context = port->scriptExecutionContext();
            if (!context)
                return;
            if (!limit--) {
                if (MessagePortPipe::queuedCount(port->m_pipe->state(port->m_side)))
                    port->m_wakeup->notify();
                return;
            }
            auto message = port->m_pipe->takeOne(port->m_side);
            if (!message) {
                if (!port->m_pipe->isOtherSideOpen(port->m_side))
                    port->close();
                return;
            }
            port->dispatchOneMessage(*context, WTF::move(*message));
            if (globalObject->drainMicrotasks())
                return;
        }
    }

    void revoke()
    {
        detach();
        m_port = nullptr;
    }

    void stop() noexcept final
    {
        Ref protectedThis { *this };
        detach();
        if (auto* port = std::exchange(m_port, nullptr))
            port->stop();
    }

private:
    void contextClosed() noexcept final { stop(); }

    explicit DeliveryTarget(MessagePort& port)
        : m_port(&port)
    {
    }

    MessagePort* m_port;
};

ExceptionOr<Ref<MessagePort>> MessagePort::tryAllocate(ScriptExecutionContext& context, Ref<MessagePortPipe>&& pipe, uint8_t side)
{
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(MessagePort)).getValue(allocation))
        return Exception { OutOfMemoryError };
    Ref port = adoptRef(*new (NotNull, allocation) MessagePort(context, WTF::move(pipe), side));
    auto delivery = port->prepareDelivery();
    if (delivery.hasException())
        return delivery.releaseException();
    return port;
}

ExceptionOr<Ref<MessagePort>> MessagePort::tryCreate(ScriptExecutionContext& context, Ref<MessagePortPipe>&& pipe, uint8_t side)
{
    auto result = tryAllocate(context, WTF::move(pipe), side);
    if (result.hasException())
        return result.releaseException();
    auto port = result.releaseReturnValue();
    port->m_deliveryState = DeliveryState::Entangled;
    port->m_pipe->attach(port->m_side, Ref { *port->m_wakeup }, port->m_deliveryContext.releaseNonNull());
    return port;
}

MessagePort::MessagePort(ScriptExecutionContext& context, Ref<MessagePortPipe>&& pipe, uint8_t side)
    : ContextDestructionObserver(&context)
    , m_pipe(WTF::move(pipe))
    , m_side(side)
{
}

MessagePort::~MessagePort()
{
    ASSERT(!m_hasRef);
    if (isEntangled())
        m_pipe->abandon(m_side);
    closeDelivery();
}

ExceptionOr<void> MessagePort::prepareDelivery()
{
    auto target = DeliveryTarget::tryCreate(*this);
    auto wakeup = MessagePortWakeup::tryCreate();
    if (!target || !wakeup)
        return Exception { OutOfMemoryError };
    auto* context = scriptExecutionContext();
    if (!context)
        return Exception { InvalidStateError };
    if (!target->attach(*context))
        return Exception { InvalidStateError };
    auto deliveryContext = context->messagePortContext();
    if (!deliveryContext)
        return Exception { OutOfMemoryError };
    if (!deliveryContext->context())
        return Exception { InvalidStateError };
    auto* globalObject = context->globalObject();
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_createNativeEventSignal(globalObject, target.get());
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (!signal)
        return Exception { InvalidStateError };
    wakeup->setSignal(*signal);
    m_deliveryTarget = WTF::move(target);
    m_wakeup = WTF::move(wakeup);
    m_deliverySignal = *signal;
    m_deliveryContext = WTF::move(deliveryContext);
    return {};
}

void MessagePort::closeDelivery()
{
    auto target = std::exchange(m_deliveryTarget, nullptr);
    if (target)
        target->revoke();
    auto wakeup = std::exchange(m_wakeup, nullptr);
    if (auto* signal = std::exchange(m_deliverySignal, nullptr))
        Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(signal);
}

ExceptionOr<void> MessagePort::postMessage(JSC::JSGlobalObject& state, JSC::JSValue messageValue, StructuredSerializeOptions&& options)
{
    auto& vm = state.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto send = isEntangled()
        ? m_pipe->tryPrepareSend(m_side)
        : Bun::Bindgen::NativeAllocationResult<MessagePortPipe::PreparedSend> { MessagePortPipe::PreparedSend {} };
    if (!send)
        return Exception { OutOfMemoryError };

    Vector<RefPtr<MessagePort>> ports;
    auto messageData = SerializedScriptValue::prepare(state, messageValue, WTF::move(options.transfer), ports, SerializationForStorage::No, SerializationContext::WorkerPostMessage);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (messageData.hasException())
        return messageData.releaseException();
    auto preparedMessage = messageData.releaseReturnValue();

    if (!isEntangled()) {
        vm.hasExceptionsAfterHandlingTraps();
        RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
        auto validation = preparedMessage.validateTransfers();
        if (validation.hasException())
            return validation.releaseException();
        preparedMessage.commit(vm);
        return {};
    }

    auto portTransfer = prepareTransfer(ports.span(), m_pipe.ptr());
    if (portTransfer.hasException())
        return portTransfer.releaseException();
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    auto validation = preparedMessage.validateTransfers();
    if (validation.hasException())
        return validation.releaseException();
    auto transferredPorts = portTransfer.releaseReturnValue().commit();
    if (transferredPorts.hasException())
        return transferredPorts.releaseException();

    send->commit(MessageWithMessagePorts { preparedMessage.commit(vm), transferredPorts.releaseReturnValue() });
    return {};
}

void MessagePort::start()
{
    if (m_started || !isEntangled())
        return;
    m_started = true;

    ASSERT(m_wakeup);
    if (MessagePortPipe::queuedCount(m_pipe->state(m_side)) || !m_pipe->isOtherSideOpen(m_side))
        m_wakeup->notify();
}

void MessagePort::close()
{
    if (isDetached())
        return;
    Ref protectedThis { *this };
    m_deliveryState.store(DeliveryState::ClosePending, std::memory_order_relaxed);

    // m_pipe is held for the port's whole lifetime (the GC thread reads
    // it in hasPendingActivity()); marking our side Closed is sufficient.
    m_pipe->close(m_side);
    jsUnref();
    queueCloseEvent();
}

void MessagePort::queueCloseEvent()
{
    auto* context = m_deliveryTarget ? m_deliveryTarget->context() : nullptr;
    if (!context || context->isJSExecutionForbidden()) {
        stop();
        return;
    }
    m_deliveryState.store(DeliveryState::ClosePending, std::memory_order_relaxed);
    m_wakeup->notify();
}

void MessagePort::dispatchCloseEvent(ScriptExecutionContext& context)
{
    Ref protectedThis { *this };
    auto* global = context.globalObject();
    Ref vm = context.vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm.get());
    if (!scope.exception() && !context.isJSExecutionForbidden()) {
        auto event = Event::tryCreate(eventNames().closeEvent, Event::CanBubble::No, Event::IsCancelable::No);
        if (event)
            EventTarget::dispatchEvent(*event);
        else {
            auto throwScope = DECLARE_THROW_SCOPE(vm.get());
            JSC::throwOutOfMemoryError(global, throwScope);
        }
    }
    m_deliveryState.store(DeliveryState::Detached, std::memory_order_relaxed);
    removeAllEventListeners();
    closeDelivery();
    if (auto* exception = scope.exception())
        reportException(global, exception);
}

void MessagePort::stop()
{
    Ref protectedThis { *this };
    if (m_deliveryState.exchange(DeliveryState::Detached, std::memory_order_relaxed) == DeliveryState::Entangled)
        m_pipe->close(m_side);
    removeAllEventListeners();
    jsUnref();
    closeDelivery();
}

TransferredMessagePort MessagePort::disentangle()
{
    ASSERT(isEntangled());

    m_deliveryState.store(DeliveryState::ClosePending, std::memory_order_relaxed);
    jsUnref();

    // Hand the pipe endpoint to its next owner. Messages that arrive while
    // in transit buffer in the pipe; the receiving context's entangle()
    // re-attaches and flushes them. We keep our own ref to the pipe so the
    // GC thread can always dereference it — our side is detached, so all
    // further operations on it are no-ops.
    m_pipe->detach(m_side);
    m_started = false;
    queueCloseEvent();

    return TransferredMessagePort { m_pipe.copyRef(), m_side };
}

void MessagePort::dispatchOneMessage(ScriptExecutionContext& context, MessageWithMessagePorts&& message)
{
    if (isDetached() || !context.globalObject())
        return;

    auto* globalObject = defaultGlobalObject(context.globalObject());
    Ref vm = globalObject->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);

    if (Zig::GlobalObject::scriptExecutionStatus(globalObject, globalObject) != ScriptExecutionStatus::Running)
        return;

    const auto dispatch = [&] {
        auto throwScope = DECLARE_THROW_SCOPE(vm);
        auto ports = MessagePort::entanglePorts(context, message.transferredPorts.mutableSpan());
        RETURN_IF_EXCEPTION(throwScope, void());
        if (ports.hasException()) {
            propagateException(*globalObject, throwScope, ports.releaseException());
            return;
        }
        auto event = MessageEvent::create(*context.jsGlobalObject(), message.message.releaseNonNull(), {}, {}, {}, ports.releaseReturnValue());
        RETURN_IF_EXCEPTION(throwScope, void());
        if (event)
            dispatchEvent(event->event);
    };
    if (!scope.exception())
        dispatch();
    if (auto* exception = scope.exception())
        reportException(globalObject, exception);
}

std::optional<JSValue> MessagePort::tryTakeMessage(JSGlobalObject* lexicalGlobalObject)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    if (!isEntangled())
        return std::nullopt;

    auto* context = scriptExecutionContext();
    if (!context)
        return std::nullopt;

    auto message = m_pipe->takeOne(m_side);
    if (!m_pipe->isOtherSideOpen(m_side) && !MessagePortPipe::queuedCount(m_pipe->state(m_side)))
        m_wakeup->notify();
    if (!message)
        return std::nullopt;

    auto ports = MessagePort::entanglePorts(*context, message->transferredPorts.mutableSpan());
    RETURN_IF_EXCEPTION(scope, {});
    if (ports.hasException()) {
        propagateException(*lexicalGlobalObject, scope, ports.releaseException());
        return {};
    }
    auto result = message->message.releaseNonNull()->deserialize(*lexicalGlobalObject, lexicalGlobalObject, ports.releaseReturnValue(), SerializationErrorMode::Throwing);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

void MessagePort::dispatchEvent(Event& event)
{
    if (isDetached())
        return;
    EventTarget::dispatchEvent(event);
}

void MessagePort::contextDestroyed(ScriptExecutionContext& context)
{
    Ref protectedThis { *this };
    setRef(false, &context);
    stop();
}

bool MessagePort::hasPendingActivity() const
{
    switch (m_deliveryState.load(std::memory_order_relaxed)) {
    case DeliveryState::ClosePending:
        return true;
    case DeliveryState::Detached:
        return false;
    case DeliveryState::Entangled:
        break;
    }
    if (!scriptExecutionContext())
        return false;
    if (m_hasCloseEventListener.load(std::memory_order_relaxed))
        return true;
    if (!m_hasMessageEventListener.load(std::memory_order_relaxed))
        return false;

    uint64_t s = m_pipe->state(m_side);
    // Keep alive if there are messages already queued for us, or the peer
    // is still open and could send more.
    return MessagePortPipe::queuedCount(s) > 0 || m_pipe->isOtherSideOpen(m_side);
}

MessagePort::PreparedTransfer::PreparedTransfer(Vector<RefPtr<MessagePort>>&& ports, Vector<TransferredMessagePort>&& transferred)
    : m_ports(WTF::move(ports))
    , m_transferred(WTF::move(transferred))
{
}

MessagePort::PreparedTransfer::PreparedTransfer(PreparedTransfer&& other) noexcept
    : m_ports(WTF::move(other.m_ports))
    , m_transferred(WTF::move(other.m_transferred))
    , m_consumed(std::exchange(other.m_consumed, true))
{
}

ExceptionOr<MessagePort::PreparedTransfer> MessagePort::prepareTransfer(std::span<const RefPtr<MessagePort>> ports, const MessagePortPipe* excludedPipe)
{
    Vector<MessagePort*> sorted;
    if (!sorted.tryReserveInitialCapacity(ports.size()))
        return Exception { OutOfMemoryError };
    for (const auto& port : ports) {
        if (!port || !port->isEntangled() || port->pipe() == excludedPipe)
            return Exception { DataCloneError };
        sorted.append(port.get());
    }
    std::sort(sorted.begin(), sorted.end(), std::less<MessagePort*> {});
    for (size_t i = 1; i < sorted.size(); ++i) {
        if (sorted[i - 1] == sorted[i])
            return Exception { DataCloneError };
    }

    Vector<TransferredMessagePort> transferred;
    if (!transferred.tryReserveInitialCapacity(ports.size()))
        return Exception { OutOfMemoryError };
    Vector<RefPtr<MessagePort>> retained;
    if (!retained.tryAppend(ports))
        return Exception { OutOfMemoryError };
    return PreparedTransfer { WTF::move(retained), WTF::move(transferred) };
}

ExceptionOr<void> MessagePort::PreparedTransfer::validate() const
{
    RELEASE_ASSERT(!m_consumed);
    for (const auto& port : m_ports) {
        if (!port->isEntangled())
            return Exception { DataCloneError };
    }
    return {};
}

ExceptionOr<Vector<TransferredMessagePort>> MessagePort::PreparedTransfer::commit()
{
    auto validation = validate();
    if (validation.hasException())
        return validation.releaseException();
    return commitValidated();
}

Vector<TransferredMessagePort> MessagePort::PreparedTransfer::commitValidated()
{
    RELEASE_ASSERT(!validate().hasException());
    m_consumed = true;
    for (const auto& port : m_ports)
        m_transferred.append(port->disentangle());
    return WTF::move(m_transferred);
}

MessagePort::PreparedMessage::PreparedMessage(SerializedScriptValue::Prepared&& serialized, PreparedTransfer&& ports)
    : m_serialized(WTF::move(serialized))
    , m_ports(WTF::move(ports))
{
}

ExceptionOr<MessagePort::PreparedMessage> MessagePort::prepareMessage(JSC::JSGlobalObject& globalObject, JSC::JSValue value, Vector<JSC::Strong<JSC::JSObject>>&& transfer)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    Vector<RefPtr<MessagePort>> ports;
    auto serialized = SerializedScriptValue::prepare(globalObject, value, WTF::move(transfer), ports, SerializationForStorage::No, SerializationContext::WorkerPostMessage);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (serialized.hasException())
        return serialized.releaseException();
    auto portTransfer = prepareTransfer(ports.span());
    if (portTransfer.hasException())
        return portTransfer.releaseException();
    return PreparedMessage { serialized.releaseReturnValue(), portTransfer.releaseReturnValue() };
}

ExceptionOr<void> MessagePort::PreparedMessage::validateForCommit(JSC::JSGlobalObject& globalObject) const
{
    auto& vm = globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    auto validation = m_serialized.validateTransfers();
    if (validation.hasException())
        return validation.releaseException();
    return m_ports.validate();
}

ExceptionOr<MessageWithMessagePorts> MessagePort::PreparedMessage::commit(JSC::JSGlobalObject& globalObject)
{
    auto validation = validateForCommit(globalObject);
    if (validation.hasException())
        return validation.releaseException();
    return commitValidated(globalObject.vm());
}

MessageWithMessagePorts MessagePort::PreparedMessage::commitValidated(JSC::VM& vm)
{
    RELEASE_ASSERT(!m_serialized.validateTransfers().hasException());
    auto ports = m_ports.commitValidated();
    return MessageWithMessagePorts { m_serialized.commit(vm), WTF::move(ports) };
}

ExceptionOr<Vector<RefPtr<MessagePort>>> MessagePort::entanglePorts(ScriptExecutionContext& context, std::span<TransferredMessagePort> transferred)
{
    auto* globalObject = context.globalObject();
    if (!globalObject)
        return Exception { InvalidStateError };
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    Vector<RefPtr<MessagePort>> ports;
    if (!ports.tryReserveInitialCapacity(transferred.size()))
        return Exception { OutOfMemoryError };
    for (const auto& endpoint : transferred) {
        RELEASE_ASSERT(endpoint.pipe && endpoint.side < 2);
        auto port = tryAllocate(context, Ref { *endpoint.pipe }, endpoint.side);
        RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
        if (port.hasException())
            return port.releaseException();
        ports.append(port.releaseReturnValue());
    }

    for (size_t i = 0; i < ports.size(); ++i) {
        transferred[i].pipe = nullptr;
        ports[i]->m_deliveryState = DeliveryState::Entangled;
        ports[i]->m_pipe->attach(ports[i]->m_side, Ref { *ports[i]->m_wakeup }, ports[i]->m_deliveryContext.releaseNonNull());
    }
    return ports;
}

void MessagePort::eventListenersDidChange()
{
    const bool closeListening = hasEventListeners(eventNames().closeEvent);
    m_hasCloseEventListener.store(closeListening, std::memory_order_relaxed);
    if (closeListening && !m_pipe->isOtherSideOpen(m_side) && m_wakeup)
        m_wakeup->notify();
    const bool listening = hasEventListeners(eventNames().messageEvent);
    const bool wasListening = m_hasMessageEventListener.exchange(listening, std::memory_order_relaxed);
    if (listening == wasListening)
        return;
    if (listening) {
        jsRef();
        start();
    } else
        jsUnref();
}

WebCoreOpaqueRoot root(MessagePort* port)
{
    return WebCoreOpaqueRoot { port };
}

void MessagePort::setRef(bool referenced, ScriptExecutionContext* context)
{
    if (m_hasRef == referenced)
        return;
    RELEASE_ASSERT(context);
    m_hasRef = referenced;
    if (referenced) {
        ref();
        context->refEventLoop();
    } else {
        context->unrefEventLoop();
        deref();
    }
}

void MessagePort::jsRef()
{
    if (!isEntangled() || (!m_pipe->isOtherSideOpen(m_side) && !MessagePortPipe::queuedCount(m_pipe->state(m_side))))
        return;
    setRef(true, scriptExecutionContext());
}

void MessagePort::jsUnref()
{
    setRef(false, scriptExecutionContext());
}

} // namespace WebCore
