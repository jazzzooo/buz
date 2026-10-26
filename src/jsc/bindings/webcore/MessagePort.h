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

#pragma once

#include "ContextDestructionObserver.h"
#include "Bindgen/NativeResult.h"
#include "EventTarget.h"
#include "ExceptionOr.h"
#include "MessagePortPipe.h"
#include "MessageWithMessagePorts.h"
#include <atomic>
#include <optional>
#include <span>
#include <wtf/FastMalloc.h>

namespace JSC {
class JSObject;
class JSValue;
}

namespace Bun {
struct NativeEventLoopSignal;
}

namespace WebCore {

class WebCoreOpaqueRoot;

struct StructuredSerializeOptions;

class MessagePort final : public ContextDestructionObserver, public EventTarget, public ThreadSafeRefCounted<MessagePort> {
    WTF_MAKE_NONCOPYABLE(MessagePort);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(MessagePort);

public:
    class PreparedTransfer {
        WTF_MAKE_NONCOPYABLE(PreparedTransfer);

    public:
        PreparedTransfer(PreparedTransfer&&) noexcept;
        ExceptionOr<void> validate() const;
        ExceptionOr<Vector<TransferredMessagePort>> commit();
        Vector<TransferredMessagePort> commitValidated();

    private:
        friend class MessagePort;
        PreparedTransfer(Vector<RefPtr<MessagePort>>&&, Vector<TransferredMessagePort>&&);
        Vector<RefPtr<MessagePort>> m_ports;
        Vector<TransferredMessagePort> m_transferred;
        bool m_consumed { false };
    };

    class PreparedMessage {
        WTF_MAKE_NONCOPYABLE(PreparedMessage);

    public:
        PreparedMessage(PreparedMessage&&) noexcept = default;
        ExceptionOr<void> validateForCommit(JSC::JSGlobalObject&) const;
        ExceptionOr<MessageWithMessagePorts> commit(JSC::JSGlobalObject&);
        // No JavaScript may run between validation and commit.
        MessageWithMessagePorts commitValidated(JSC::VM&);

    private:
        friend class MessagePort;
        PreparedMessage(SerializedScriptValue::Prepared&&, PreparedTransfer&&);
        SerializedScriptValue::Prepared m_serialized;
        PreparedTransfer m_ports;
    };

    static ExceptionOr<PreparedMessage> prepareMessage(JSC::JSGlobalObject&, JSC::JSValue, Vector<JSC::Strong<JSC::JSObject>>&& transfer);

    static ExceptionOr<Ref<MessagePort>> tryCreate(ScriptExecutionContext&, Ref<MessagePortPipe>&&, uint8_t side);
    virtual ~MessagePort();

    ExceptionOr<void> postMessage(JSC::JSGlobalObject&, JSC::JSValue message, StructuredSerializeOptions&&);

    void start();
    void close();

    // Transfer machinery.
    static ExceptionOr<PreparedTransfer> prepareTransfer(std::span<const RefPtr<MessagePort>>, const MessagePortPipe* excludedPipe = nullptr);
    static ExceptionOr<Vector<RefPtr<MessagePort>>> entanglePorts(ScriptExecutionContext&, std::span<TransferredMessagePort>);

    bool started() const { return m_started; }
    bool isDetached() const { return !isEntangled(); }

    void dispatchOneMessage(ScriptExecutionContext&, MessageWithMessagePorts&&);

    MessagePortPipe* pipe() const { return m_pipe.ptr(); }
    uint8_t side() const { return m_side; }

    void ref() const { ThreadSafeRefCounted::ref(); }
    void deref() const { ThreadSafeRefCounted::deref(); }

    // EventTarget.
    EventTargetInterface eventTargetInterface() const final { return MessagePortEventTargetInterfaceType; }
    ScriptExecutionContext* scriptExecutionContext() const final { return this->ContextDestructionObserver::scriptExecutionContext(); }
    void refEventTarget() final { ref(); }
    void derefEventTarget() final { deref(); }
    void dispatchEvent(Event&) final;

    // node:worker_threads receiveMessageOnPort — synchronous single pop.
    std::optional<JSValue> tryTakeMessage(JSGlobalObject*);

    bool hasPendingActivity() const;

    void jsRef();
    void jsUnref();
    bool jsHasRef() { return m_hasRef; }

private:
    TransferredMessagePort disentangle();
    MessagePort(ScriptExecutionContext&, Ref<MessagePortPipe>&&, uint8_t side);
    // A prepared receiver retains its pipe but does not yet own the endpoint.
    static ExceptionOr<Ref<MessagePort>> tryAllocate(ScriptExecutionContext&, Ref<MessagePortPipe>&&, uint8_t side);
    ExceptionOr<void> prepareDelivery();
    void closeDelivery();
    void queueCloseEvent();
    void dispatchCloseEvent(ScriptExecutionContext&);
    void stop();

    void eventListenersDidChange() final;
    void setRef(bool, ScriptExecutionContext*);

    void contextDestroyed(ScriptExecutionContext&) final;

    bool isEntangled() const { return m_deliveryState.load(std::memory_order_relaxed) == DeliveryState::Entangled; }

    // Held for the port's entire lifetime — never nulled — so that the GC
    // thread's hasPendingActivity() can dereference it without racing the
    // mutator. close()/disentangle() update delivery and pipe-side state instead.
    const Ref<MessagePortPipe> m_pipe;
    const uint8_t m_side { 0 };
    class DeliveryTarget;
    RefPtr<DeliveryTarget> m_deliveryTarget;
    RefPtr<MessagePortPipe::Wakeup> m_wakeup;
    RefPtr<MessagePortContext> m_deliveryContext;
    Bun::NativeEventLoopSignal* m_deliverySignal { nullptr };

    bool m_started { false };
    enum class DeliveryState : uint8_t { Detached, Entangled, ClosePending };
    std::atomic<DeliveryState> m_deliveryState { DeliveryState::Detached };
    std::atomic<bool> m_hasMessageEventListener { false };
    std::atomic<bool> m_hasCloseEventListener { false };
    bool m_hasRef { false };

};

WebCoreOpaqueRoot root(MessagePort*);

} // namespace WebCore
