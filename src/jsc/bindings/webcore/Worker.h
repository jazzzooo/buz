/*
 * Copyright (C) 2008, 2010, 2016 Apple Inc. All Rights Reserved.
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
 */

#pragma once

#include "MessageQueue.h"

#include "EventTarget.h"
#include "MessageWithMessagePorts.h"
#include "SchemaBindings.h"
#include "WorkerOptions.h"
#include <JavaScriptCore/RuntimeFlags.h>
#include <optional>
#include <wtf/Deque.h>
#include <wtf/text/AtomStringHash.h>
#include "ContextDestructionObserver.h"
#include "Event.h"

namespace JSC {
class JSObject;
class JSValue;
}

namespace WebCore {

class ScriptExecutionContext;
struct StructuredSerializeOptions;
struct WorkerOptions;

/// Parent-side handle for a Web or Node worker thread.
///
/// Lifetime / ownership (see also the header comment in web_worker.zig):
///
///   JSWorker (GC'd JSCell)  ──Ref──►  Worker  ──owns──►  Zig WebWorker
///     parent thread                   ThreadSafeRefCounted   default_allocator
///
/// Refs held on this object:
///   - JSWorker wrapper       from construct() until GC finalize
///   - worker thread          taken in prepare() before the thread is spawned;
///                            dropped on the parent by exit delivery or thread join
///   - delivery endpoints     released on their VM threads during shutdown
///   - transient Ref{*this} captured by posted tasks
///
/// impl_ (Zig WebWorker*) is owned by this object and freed in ~Worker(), so
/// terminate()/ref()/unref() can never see a dangling pointer while JS holds
/// the wrapper.
///
/// State machine:
///
///     ┌────────┐  dispatchOnline   ┌────────┐
///     │Pending │ ────────────────► │Running │
///     └───┬────┘  (worker thread,  └───┬────┘
///         │        under lock)         │
///         │                            │
///         └────────────┬───────────────┘
///                      │ close task (parent thread)
///                      ▼
///                 ┌────────┐  'close' event   ┌────────┐
///                 │Closing │ ───────────────► │ Closed │
///                 └────────┘  dispatched      └────────┘
///
/// Closing exists so that inside the 'close'/'exit' handler threadId reads
/// -1 and isOnline() is false (old ClosingFlag behaviour) while postMessage()
/// — which only gates on Closed (old TerminatedFlag behaviour) — still
/// accepts and silently drops the message, matching browser/Node semantics.
///
/// m_terminateRequested is orthogonal: set once by terminate(), gates
/// dispatchEvent()/setKeepAlive(), and is mirrored into the Zig side so the
/// worker loop can observe it.
class Worker final : public ThreadSafeRefCounted<Worker>, public EventTargetWithInlineData, private ContextDestructionObserver {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Worker);

public:
    enum class State : uint8_t {
        Pending, // created; worker thread starting up
        Running, // dispatchOnline has fired; worker event loop is spinning
        Closing, // worker thread has exited; close task is dispatching the 'close' event
        Closed, // close event dispatched on the parent; worker is fully done
    };

    static ExceptionOr<Ref<Worker>> prepare(ScriptExecutionContext&, const String& url, WorkerOptions&&);
    ExceptionOr<void> commitStartup(JSC::JSGlobalObject&, MessagePort::PreparedMessage&&);
    void cancelStartup();
    ~Worker();

    ExceptionOr<void> postMessage(JSC::JSGlobalObject&, JSC::JSValue message, StructuredSerializeOptions&&);

    using ThreadSafeRefCounted::deref;
    using ThreadSafeRefCounted::ref;

    // -- Parent-thread API (called from JS on the owning thread) -------------
    void terminate();
    void setKeepAlive(bool);
    void dispatchEvent(Event&);
    // Returns true if the task was accepted (queued to Pending or posted to
    // Running). Returns false if the worker is Closing/Closed or its context
    // is already gone — the caller must handle cleanup itself.
    bool postTaskToWorkerGlobalScope(Function<void(ScriptExecutionContext&)>&&);

    // -- State queries (safe from any thread; all loads are atomic) ----------
    bool wasTerminated() const { return m_state.load() >= State::Closing; }
    bool hasPendingActivity() const { return m_state.load() != State::Closed; }
    bool isOnline() const { return m_state.load() == State::Running; }

    const String& name() const { return m_options.name; }
    ScriptExecutionContext* scriptExecutionContext() const final { return ContextDestructionObserver::scriptExecutionContext(); }
    ScriptExecutionContextIdentifier clientIdentifier() const { return m_clientIdentifier; }
    WorkerOptions& options() { return m_options; }

    ExceptionOr<void> dispatchOnline(Zig::GlobalObject* workerGlobalObject);
    void fireEarlyMessages(Zig::GlobalObject* workerGlobalObject);
    Bun::Bindgen::NativeAllocationResult<void> dispatchErrorWithMessage(const WTF::String& message);
    ExceptionOr<bool> dispatchErrorWithValue(Zig::GlobalObject* workerGlobalObject, JSValue value);
    bool dispatchExit(int32_t exitCode);
    void finishExit(int32_t exitCode, bool dispatchEvent);

    struct MessageInbox {
        void close();
        bool setSignal(Bun::NativeEventLoopSignal*);
        void notify();
        WTF::Lock lock;
        MessageQueue queue WTF_GUARDED_BY_LOCK(lock);
        Bun::NativeEventLoopSignal* signal WTF_GUARDED_BY_LOCK(lock) { nullptr };
        std::atomic<bool> closed { false };
        std::atomic<bool> drainScheduled { false };
    };

    void enqueueToParent(std::unique_ptr<MessageQueue::Node>&&);
    void drainToWorker(ScriptExecutionContext&);

private:
    Worker(ScriptExecutionContext&, WorkerOptions&&);
    class ParentMessageDelivery;
    class WorkerMessageDelivery;
    template<bool isExit> class LifecycleDelivery;
    ExceptionOr<void> prepareParentMessageDelivery();
    template<bool isExit> ExceptionOr<Ref<LifecycleDelivery<isExit>>> prepareLifecycleDelivery();
    void closeLifecycleDelivery();
    ExceptionOr<void> prepareWorkerMessageDelivery(ScriptExecutionContext&);
    void closeParentMessageDelivery();

    EventTargetInterface eventTargetInterface() const final { return WorkerEventTargetInterfaceType; }
    void refEventTarget() final { ref(); }
    void derefEventTarget() final { deref(); }
    void eventListenersDidChange() final {};
    void contextDestroyed(ScriptExecutionContext&) final;

    void enqueueToWorker(std::unique_ptr<MessageQueue::Node>&&);
    void drainToParent(ScriptExecutionContext&);
    void finalizeExit(int32_t exitCode, bool dispatchEvent);

    WorkerOptions m_options;

    // Messages posted before the worker reaches Running are queued here and
    // flushed by fireEarlyMessages(). The Pending→Running transition happens
    // under this lock so postTaskToWorkerGlobalScope never loses a task.
    Lock m_pendingTasksMutex;
    Deque<Function<void(ScriptExecutionContext&)>> m_pendingTasks WTF_GUARDED_BY_LOCK(m_pendingTasksMutex);

    MessageInbox m_toWorker; // messages parent → worker, drained on the worker thread
    MessageInbox m_toParent; // messages worker → parent, drained on the parent thread
    Bun::NativeEventLoopSignal* m_parentMessageSignal { nullptr };
    // Published before spawning; retained unchanged until Worker destruction.
    RefPtr<LifecycleDelivery<true>> m_exitDelivery;
    RefPtr<LifecycleDelivery<false>> m_onlineDelivery;
    // Parent-thread state includes the batch held outside the inbox lock.
    bool m_parentDrainActive { false };
    std::optional<int32_t> m_pendingExitCode;

    std::atomic<State> m_state { State::Pending };
    std::atomic<bool> m_terminateRequested { false };
    std::atomic<bool> m_exitFinalized { false };

    // Stable for the process lifetime; used with ScriptExecutionContext::
    // postTaskTo() so the worker thread never dereferences the parent context
    // pointer (which could be freed concurrently).
    const ScriptExecutionContextIdentifier m_parentContextId;
    // This worker's own context identifier (allocated at construction, bound
    // once the worker VM is up).
    const ScriptExecutionContextIdentifier m_clientIdentifier;

    // Owned Zig WebWorker*. Written once in prepare(), read only on the parent
    // thread (terminate/setKeepAlive) or in the close task (also parent thread).
    // Freed in ~Worker(). Never null once prepare() returns successfully.
    Bun::WebWorkerState* impl_ { nullptr };
};

} // namespace WebCore
