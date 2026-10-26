/*
 * Copyright (C) 2008-2017 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Google Inc. All Rights Reserved.
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

#include "config.h"
#include "Worker.h"

#include "ErrorCode.h"
#include "ErrorEvent.h"
#include "Event.h"
#include "EventNames.h"
#include "StructuredSerializeOptions.h"
#include "StructuredSerializeBinding.h"
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/ScriptCallStack.h>
#include <wtf/Scope.h>
#include "SerializedScriptValue.h"
#include "ScriptExecutionContext.h"
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSModuleLoader.h>
#include "MessageEvent.h"
#include "BunWorkerGlobalScope.h"
#include "CloseEvent.h"
#include "SchemaBindings.h"
#include "JSMessagePort.h"
#include "JSBroadcastChannel.h"
#include "JSDOMExceptionHandling.h"
#include "NativeEventLoopTarget.h"
#include <JavaScriptCore/TopExceptionScope.h>
#include <algorithm>
#include <type_traits>
#include <wtf/text/StringImpl.h>

namespace WebCore {

class Worker::ParentMessageDelivery final : public Bun::NativeEventLoopTarget {
public:
    static RefPtr<ParentMessageDelivery> tryCreate(Worker& worker)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(ParentMessageDelivery)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) ParentMessageDelivery(worker));
    }

    void run(JSC::JSGlobalObject*) noexcept final
    {
        RefPtr worker = m_worker;
        if (!worker)
            return;
        auto* context = worker->scriptExecutionContext();
        if (context)
            worker->drainToParent(*context);
    }

    void stop() noexcept final
    {
        auto worker = std::exchange(m_worker, nullptr);
        if (worker)
            worker->m_toParent.close();
    }

private:
    explicit ParentMessageDelivery(Worker& worker)
        : m_worker(&worker)
    {
    }

    RefPtr<Worker> m_worker;
};

template<bool isExit>
class Worker::LifecycleDelivery final : public Bun::NativeEventLoopTarget {
public:
    static RefPtr<LifecycleDelivery> tryCreate(Worker& worker)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(LifecycleDelivery)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) LifecycleDelivery(worker));
    }

    ~LifecycleDelivery()
    {
        ASSERT(!m_ownerSignal);
        Locker locker { m_lock };
        ASSERT(!m_sender);
    }

    void setSignal(Bun::NativeEventLoopSignal* signal)
    {
        ASSERT(!m_ownerSignal);
        m_ownerSignal = signal;
        Locker locker { m_lock };
        m_sender = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_retainNativeEventSignal(signal);
    }

    bool notify(int32_t exitCode) requires(isExit) { return notifyValue(exitCode); }
    bool notify() requires(!isExit) { return notifyValue(0); }

private:
    bool notifyValue(int32_t exitCode)
    {
        Bun::NativeEventLoopSignal* sender;
        {
            Locker locker { m_lock };
            if (!m_sender)
                return false;
            RELEASE_ASSERT(!m_posted);
            m_posted = true;
            m_exitCode = exitCode;
            sender = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_retainNativeEventSignal(m_sender);
        }
        bool accepted = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_notifyNativeEventSignal(sender);
        Bun::Bindgen::Engine::releaseNativeEventLoopSignal(sender);
        return accepted;
    }

public:
    void run(JSC::JSGlobalObject*) noexcept final
    {
        RefPtr worker = m_worker;
        if (!worker)
            return;
        [[maybe_unused]] int32_t exitCode;
        {
            Locker locker { m_lock };
            RELEASE_ASSERT(m_posted);
            exitCode = m_exitCode;
        }
        if constexpr (isExit)
            worker->finishExit(exitCode, true);
        else {
            stop();
            if (worker->hasEventListeners(eventNames().openEvent))
                worker->dispatchSimpleEvent(eventNames().openEvent);
        }
    }

    void stop() noexcept final
    {
        Ref protectedThis { *this };
        auto worker = std::exchange(m_worker, nullptr);
        auto* owner = std::exchange(m_ownerSignal, nullptr);
        Bun::NativeEventLoopSignal* sender;
        {
            Locker locker { m_lock };
            sender = std::exchange(m_sender, nullptr);
        }
        if (sender)
            Bun::Bindgen::Engine::releaseNativeEventLoopSignal(sender);
        if (owner)
            Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(owner);
    }

private:
    explicit LifecycleDelivery(Worker& worker)
        : m_worker(&worker)
    {
    }

    RefPtr<Worker> m_worker;
    Bun::NativeEventLoopSignal* m_ownerSignal { nullptr };
    Lock m_lock;
    Bun::NativeEventLoopSignal* m_sender WTF_GUARDED_BY_LOCK(m_lock) { nullptr };
    int32_t m_exitCode WTF_GUARDED_BY_LOCK(m_lock) { 0 };
    bool m_posted WTF_GUARDED_BY_LOCK(m_lock) { false };
};

class Worker::WorkerMessageDelivery final : public Bun::NativeEventLoopTarget, public ScriptExecutionContext::NativeLifetime {
public:
    static RefPtr<WorkerMessageDelivery> tryCreate(Worker& worker)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(WorkerMessageDelivery)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) WorkerMessageDelivery(worker));
    }

    ~WorkerMessageDelivery()
    {
        ASSERT(!m_signal);
        detach();
    }

    void setSignal(Bun::NativeEventLoopSignal* signal)
    {
        ASSERT(!m_signal);
        m_signal = signal;
    }

    void run(JSC::JSGlobalObject*) noexcept final
    {
        RefPtr worker = m_worker;
        auto* scriptContext = context();
        if (worker && scriptContext)
            worker->drainToWorker(*scriptContext);
    }

    void stop() noexcept final
    {
        Ref protectedThis { *this };
        detach();
        auto worker = std::exchange(m_worker, nullptr);
        auto* signal = std::exchange(m_signal, nullptr);
        if (worker)
            worker->m_toWorker.close();
        if (signal)
            Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(signal);
    }

private:
    explicit WorkerMessageDelivery(Worker& worker)
        : m_worker(&worker)
    {
    }

    void contextClosed() noexcept final { stop(); }

    // Worker VM endpoints are closed before the thread-held Worker ref is released.
    RefPtr<Worker> m_worker;
    Bun::NativeEventLoopSignal* m_signal { nullptr };
};

Worker::Worker(ScriptExecutionContext& context, WorkerOptions&& options)
    : EventTargetWithInlineData()
    , ContextDestructionObserver(&context)
    , m_options(WTF::move(options))
    , m_parentContextId(context.identifier())
    , m_clientIdentifier(ScriptExecutionContext::generateIdentifier())
{
}

ExceptionOr<Ref<Worker>> Worker::prepare(ScriptExecutionContext& context, const String& urlInit, WorkerOptions&& options)
{
    auto scope = DECLARE_THROW_SCOPE(context.jsGlobalObject()->vm());
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(Worker)).getValue(allocation))
        return Exception { OutOfMemoryError };
    auto worker = adoptRef(*new (NotNull, allocation) Worker(context, WTF::move(options)));

    WTF::String url = urlInit;
    if (url.startsWith("file://"_s)) {
        WTF::URL urlObject = WTF::URL(url);
        if (urlObject.isValid()) {
            url = urlObject.fileSystemPath();
        } else {
            return Exception { TypeError, makeString("Invalid file URL: \""_s, urlInit, '"') };
        }
    }
    auto& preloadModuleStrings = worker->m_options.preloadModules;
    for (auto& str : preloadModuleStrings) {
        if (str.startsWith("file://"_s)) {
            WTF::URL urlObject = WTF::URL(str);
            if (!urlObject.isValid()) {
                return Exception { TypeError, makeString("Invalid file URL: \""_s, str, '"') };
            }
            str = urlObject.fileSystemPath();
        }
    }

    std::span<const WTF::String> execArgv = worker->m_options.execArgv
                                                .transform([](Vector<String>& vec) -> std::span<const WTF::String> {
                                                    return { vec.begin(), vec.size() };
                                                })
                                                .value_or(std::span<const WTF::String> {});

    auto cancelDelivery = makeScopeExit([&] {
        worker->closeParentMessageDelivery();
        worker->closeLifecycleDelivery();
    });
    auto delivery = worker->prepareParentMessageDelivery();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (delivery.hasException())
        return delivery.releaseException();
    auto exitDelivery = worker->prepareLifecycleDelivery<true>();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (exitDelivery.hasException())
        return exitDelivery.releaseException();
    worker->m_exitDelivery = exitDelivery.releaseReturnValue();
    auto onlineDelivery = worker->prepareLifecycleDelivery<false>();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (onlineDelivery.hasException())
        return onlineDelivery.releaseException();
    worker->m_onlineDelivery = onlineDelivery.releaseReturnValue();

    // Exit delivery or the parent's thread join releases this reference.
    worker->ref();
    auto releaseThreadReference = makeScopeExit([&] {
        worker->m_state.store(State::Closed);
        worker->deref();
    });

    auto creationResult = Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerCreate(
        context.jsGlobalObject(),
        worker.ptr(),
        worker->m_options.name,
        url,
        static_cast<uint32_t>(worker->m_parentContextId),
        static_cast<uint32_t>(worker->m_clientIdentifier),
        worker->m_options.mini,
        worker->m_options.unref,
        worker->m_options.evalMode,
        !worker->m_options.execArgv.has_value(),
        std::span<const WTF::String> { worker->m_options.argv.begin(), worker->m_options.argv.size() },
        execArgv,
        std::span<const WTF::String> { preloadModuleStrings.begin(), preloadModuleStrings.size() });
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });

    preloadModuleStrings.clear();

    if (!creationResult.state) {
        return Exception { TypeError, WTF::move(creationResult.errorMessage) };
    }

    // The new thread cannot access Worker until startup is committed.
    worker->impl_ = *creationResult.state;
    releaseThreadReference.release();
    cancelDelivery.release();

    return worker;
}

ExceptionOr<void> Worker::commitStartup(JSC::JSGlobalObject& globalObject, MessagePort::PreparedMessage&& prepared)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto validation = prepared.validateForCommit(globalObject);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (validation.hasException())
        return validation.releaseException();
    if (m_exitFinalized.load() || m_terminateRequested.load() || !scriptExecutionContext())
        return Exception { InvalidStateError };
    auto message = prepared.commitValidated(globalObject.vm());
    m_options.workerDataAndEnvironmentData = WTF::move(message.message);
    m_options.dataMessagePorts = WTF::move(message.transferredPorts);
    Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerCommitStartup(impl_);
    return {};
}

void Worker::cancelStartup()
{
    if (m_exitFinalized.load())
        return;
    terminate();
    finishExit(0, false);
}

Worker::~Worker()
{
    closeLifecycleDelivery();
    closeParentMessageDelivery();
    m_toWorker.close();
    m_toParent.close();
    if (impl_) {
        Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerDestroy(impl_);
    }
}

template<bool isExit>
ExceptionOr<Ref<Worker::LifecycleDelivery<isExit>>> Worker::prepareLifecycleDelivery()
{
    auto target = LifecycleDelivery<isExit>::tryCreate(*this);
    if (!target)
        return Exception { OutOfMemoryError };
    auto* global = scriptExecutionContext()->globalObject();
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_createNativeEventSignal(global, target.get());
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (!signal)
        return Exception { InvalidStateError };
    target->setSignal(*signal);
    return target.releaseNonNull();
}

void Worker::closeLifecycleDelivery()
{
    if (m_exitDelivery)
        m_exitDelivery->stop();
    if (m_onlineDelivery)
        m_onlineDelivery->stop();
}

ExceptionOr<void> Worker::prepareParentMessageDelivery()
{
    auto target = ParentMessageDelivery::tryCreate(*this);
    if (!target)
        return Exception { OutOfMemoryError };
    auto* global = scriptExecutionContext()->globalObject();
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_createNativeEventSignal(global, target.get());
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (!signal)
        return Exception { InvalidStateError };
    m_parentMessageSignal = *signal;
    if (!m_toParent.setSignal(*signal)) {
        closeParentMessageDelivery();
        return Exception { InvalidStateError };
    }
    return {};
}

ExceptionOr<void> Worker::prepareWorkerMessageDelivery(ScriptExecutionContext& context)
{
    auto target = WorkerMessageDelivery::tryCreate(*this);
    if (!target)
        return Exception { OutOfMemoryError };
    if (!target->attach(context))
        return Exception { InvalidStateError };
    auto* global = context.globalObject();
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_createNativeEventSignal(global, target.get());
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (!signal)
        return Exception { InvalidStateError };
    target->setSignal(*signal);
    if (!m_toWorker.setSignal(*signal)) {
        target->stop();
        return Exception { InvalidStateError };
    }
    return {};
}

void Worker::closeParentMessageDelivery()
{
    m_toParent.close();
    if (auto* signal = std::exchange(m_parentMessageSignal, nullptr))
        Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(signal);
}

void Worker::MessageInbox::close()
{
    MessageQueue dropped;
    Bun::NativeEventLoopSignal* releasedSignal;
    {
        Locker locker { lock };
        closed.store(true, std::memory_order_release);
        drainScheduled.store(false, std::memory_order_relaxed);
        dropped = std::exchange(queue, {});
        releasedSignal = std::exchange(signal, nullptr);
    }
    if (releasedSignal)
        Bun::Bindgen::Engine::releaseNativeEventLoopSignal(releasedSignal);
}

bool Worker::MessageInbox::setSignal(Bun::NativeEventLoopSignal* preparedSignal)
{
    Locker locker { lock };
    if (closed.load(std::memory_order_relaxed))
        return false;
    RELEASE_ASSERT(!signal);
    signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_retainNativeEventSignal(preparedSignal);
    return true;
}

void Worker::MessageInbox::notify()
{
    Bun::NativeEventLoopSignal* sender;
    {
        Locker locker { lock };
        if (closed.load(std::memory_order_relaxed))
            return;
        RELEASE_ASSERT(signal);
        sender = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_retainNativeEventSignal(signal);
    }
    bool accepted = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_notifyNativeEventSignal(sender);
    Bun::Bindgen::Engine::releaseNativeEventLoopSignal(sender);
    if (!accepted)
        close();
}

void Worker::contextDestroyed(ScriptExecutionContext&)
{
    Ref protectedThis { *this };
    closeLifecycleDelivery();
    closeParentMessageDelivery();
    m_toWorker.close();
    m_toParent.close();
}

// ---- Parent-thread API ------------------------------------------------------

ExceptionOr<void> Worker::postMessage(JSC::JSGlobalObject& state, JSC::JSValue messageValue, StructuredSerializeOptions&& options)
{
    if (m_state.load() == State::Closed)
        return Exception { InvalidStateError, "Worker has been terminated"_s };

    auto scope = DECLARE_THROW_SCOPE(state.vm());
    auto node = MessageQueue::Node::tryCreate();
    if (!node)
        return Exception { OutOfMemoryError };
    auto prepared = MessagePort::prepareMessage(state, messageValue, WTF::move(options.transfer));
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (prepared.hasException())
        return prepared.releaseException();
    auto message = prepared.releaseReturnValue().commit(state);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (message.hasException())
        return message.releaseException();
    node->message = message.releaseReturnValue();
    enqueueToWorker(WTF::move(node));
    return {};
}

void Worker::enqueueToWorker(std::unique_ptr<MessageQueue::Node>&& message)
{
    {
        Locker locker { m_toWorker.lock };
        if (m_toWorker.closed.load(std::memory_order_relaxed))
            return;
        m_toWorker.queue.append(WTF::move(message));
        // Pending workers begin draining after their entry point has loaded.
        if (m_state.load() != State::Running || m_toWorker.drainScheduled.load(std::memory_order_relaxed))
            return;
        m_toWorker.drainScheduled.store(true, std::memory_order_relaxed);
    }
    m_toWorker.notify();
}

void Worker::enqueueToParent(std::unique_ptr<MessageQueue::Node>&& message)
{
    {
        Locker locker { m_toParent.lock };
        if (m_toParent.closed.load(std::memory_order_relaxed))
            return;
        m_toParent.queue.append(WTF::move(message));
        if (m_toParent.drainScheduled.load(std::memory_order_relaxed))
            return;
        m_toParent.drainScheduled.store(true, std::memory_order_relaxed);
    }
    m_toParent.notify();
}

// Worker inboxes do not transfer, so a drain can take a batch while holding
// the lock once and preserve the undelivered tail ahead of new messages.
static bool drainInbox(Worker::MessageInbox& inbox, Zig::GlobalObject* globalObject, ScriptExecutionContext& context, EventTarget& target)
{
    size_t limit;
    MessageQueue batch;
    {
        Locker locker { inbox.lock };
        if (inbox.closed.load(std::memory_order_relaxed) || inbox.queue.isEmpty()) {
            inbox.drainScheduled.store(false, std::memory_order_relaxed);
            return false;
        }
        limit = std::max<size_t>(inbox.queue.size(), 1000);
        batch = std::exchange(inbox.queue, {});
    }

    while (true) {
        while (!batch.isEmpty()) {
            if (inbox.closed.load(std::memory_order_acquire))
                return false;
            if (limit-- == 0) {
                // Yield to the rest of the event loop. Return the undrained
                // tail to the front of the inbox so it stays ahead of
                // anything enqueued concurrently; caller reschedules.
                Locker locker { inbox.lock };
                if (inbox.closed.load(std::memory_order_relaxed))
                    return false;
                inbox.queue.prepend(WTF::move(batch));
                return true;
            }
            auto node = batch.takeFirst();
            {
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
                const auto deliver = [&](auto& message) {
                    auto throwScope = DECLARE_THROW_SCOPE(globalObject->vm());
                    using Payload = std::remove_cvref_t<decltype(message)>;
                    if constexpr (std::is_same_v<Payload, MessageWithMessagePorts>) {
                        auto ports = MessagePort::entanglePorts(context, message.transferredPorts.mutableSpan());
                        RETURN_IF_EXCEPTION(throwScope, void());
                        if (ports.hasException()) {
                            propagateException(*globalObject, throwScope, ports.releaseException());
                            return;
                        }
                        auto event = MessageEvent::create(*context.jsGlobalObject(), message.message.releaseNonNull(), nullptr, ports.releaseReturnValue());
                        RETURN_IF_EXCEPTION(throwScope, void());
                        if (event)
                            target.dispatchEvent(event->event);
                    } else {
                        ErrorEvent::Init init;
                        if constexpr (std::is_same_v<Payload, MessageQueue::ErrorMessage>)
                            init.message = message.text;
                        else {
                            init.error = message.value->deserialize(*globalObject, globalObject);
                            RETURN_IF_EXCEPTION(throwScope, void());
                        }
                        ErrorEvent::dispatch(target, init, EventIsTrusted::Yes);
                    }
                };
                if (!scope.exception())
                    std::visit(deliver, node->message);
                if (auto* exception = scope.exception())
                    reportException(globalObject, exception);
            }

            if (globalObject->drainMicrotasks()) {
                inbox.close();
                return false;
            }
        }

        // Batch exhausted — see if more arrived while we were dispatching.
        Locker locker { inbox.lock };
        if (inbox.closed.load(std::memory_order_relaxed) || inbox.queue.isEmpty()) {
            inbox.drainScheduled.store(false, std::memory_order_relaxed);
            return false;
        }
        if (limit == 0)
            return true; // budget spent; caller reschedules
        batch = std::exchange(inbox.queue, {});
    }
}

void Worker::drainToWorker(ScriptExecutionContext& context)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(context.jsGlobalObject());
    if (!globalObject) {
        m_toWorker.close();
        return;
    }
    bool reschedule = drainInbox(m_toWorker, globalObject, context, globalObject->globalEventScope.get());
    if (reschedule) {
        m_toWorker.notify();
    }
}

void Worker::drainToParent(ScriptExecutionContext& context)
{
    if (m_parentDrainActive)
        return;
    Ref protectedThis { *this };
    m_parentDrainActive = true;
    auto finishDrain = makeScopeExit([&] { m_parentDrainActive = false; });

    auto* globalObject = defaultGlobalObject(context.jsGlobalObject());
    bool reschedule = false;
    if (globalObject)
        reschedule = drainInbox(m_toParent, globalObject, context, *this);
    else
        m_toParent.close();
    if (reschedule)
        m_toParent.notify();

    if (reschedule && !m_toParent.closed.load(std::memory_order_acquire))
        return;
    if (m_pendingExitCode)
        finalizeExit(*m_pendingExitCode, scriptExecutionContext() && globalObject);
}

void Worker::terminate()
{
    if (m_terminateRequested.exchange(true))
        return;
    m_toWorker.close();
    m_toParent.close();
    Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerNotifyNeedTermination(impl_);
}

void Worker::setKeepAlive(bool keepAlive)
{
    // Once terminate() has been called or the close task has started, the
    // worker no longer participates in the parent's liveness — the close
    // task is the last thing to touch parent_poll_ref.
    if (m_terminateRequested.load() || m_state.load() >= State::Closing)
        return;
    Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerSetRef(impl_, keepAlive);
}

void Worker::dispatchEvent(Event& event)
{
    // Suppress user-visible events once terminate() has been called or the
    // worker has closed. The close event itself bypasses this (dispatchExit
    // calls EventTargetWithInlineData::dispatchEvent directly) so that
    // `await worker.terminate()` still resolves.
    if (m_terminateRequested.load() || m_state.load() == State::Closed)
        return;
    EventTargetWithInlineData::dispatchEvent(event);
}

bool Worker::postTaskToWorkerGlobalScope(Function<void(ScriptExecutionContext&)>&& task)
{
    {
        Locker lock(m_pendingTasksMutex);
        switch (m_state.load()) {
        case State::Pending:
            // Worker VM not up yet; queue for fireEarlyMessages().
            m_pendingTasks.append(WTF::move(task));
            return true;
        case State::Running:
            break;
        case State::Closing:
        case State::Closed:
            // Worker VM is gone; drop immediately (silent no-op).
            // postMessage() goes through enqueueToWorker(), not here — the
            // only user is getHeapSnapshot().
            return false;
        }
    }
    return ScriptExecutionContext::postTaskTo(m_clientIdentifier, WTF::move(task));
}

// ---- Worker-thread entry points ---------------------------------------------

ExceptionOr<void> Worker::dispatchOnline(Zig::GlobalObject* workerGlobalObject)
{
    auto* thisContext = workerGlobalObject->scriptExecutionContext();
    if (!thisContext)
        return Exception { InvalidStateError };
    auto delivery = prepareWorkerMessageDelivery(*thisContext);
    if (delivery.hasException())
        return delivery.releaseException();

    m_onlineDelivery->notify();

    RELEASE_ASSERT(&thisContext->vm() == &workerGlobalObject->vm());
    RELEASE_ASSERT(thisContext == workerGlobalObject->globalEventScope->scriptExecutionContext());

    // Pending→Running under the same lock postTaskToWorkerGlobalScope uses, so
    // a message post racing this transition either queues (drained below by
    // fireEarlyMessages) or posts directly — never both, never neither.
    Locker lock(m_pendingTasksMutex);
    m_state.store(State::Running);
    return {};
}

// Kick off the first drain of messages that arrived before the worker was
// online. A parent enqueue that observed State::Running (set in
// dispatchOnline, which runs just before fireEarlyMessages) may have already
// scheduled one — drainScheduled, set under the inbox lock, arbitrates.
static inline void workerScheduleInitialDrain(Worker& worker, Worker::MessageInbox& inbox, ScriptExecutionContext& ctx, bool immediately = true)
{
    {
        Locker locker { inbox.lock };
        if (inbox.closed.load(std::memory_order_relaxed) || inbox.queue.isEmpty() || inbox.drainScheduled.load(std::memory_order_relaxed))
            return;
        inbox.drainScheduled.store(true, std::memory_order_relaxed);
    }
    if (immediately)
        worker.drainToWorker(ctx);
    else
        inbox.notify();
}

void Worker::fireEarlyMessages(Zig::GlobalObject* workerGlobalObject)
{
    auto tasks = [&]() {
        Locker lock(m_pendingTasksMutex);
        return std::exchange(m_pendingTasks, {});
    }();
    auto* thisContext = workerGlobalObject->scriptExecutionContext();

    if (workerGlobalObject->globalEventScope->hasActiveEventListeners(eventNames().messageEvent)) {
        for (auto& task : tasks) {
            task(*thisContext);
        }
        workerScheduleInitialDrain(*this, m_toWorker, *thisContext);
    } else if (tasks.isEmpty()) {
        workerScheduleInitialDrain(*this, m_toWorker, *thisContext, false);
    } else {
        thisContext->postTask([tasks = WTF::move(tasks), protectedThis = Ref { *this }](auto& ctx) mutable {
            for (auto& task : tasks) {
                task(ctx);
            }
            workerScheduleInitialDrain(protectedThis.get(), protectedThis->m_toWorker, ctx);
        });
    }
}

Bun::Bindgen::NativeAllocationResult<void> Worker::dispatchErrorWithMessage(const WTF::String& message)
{
    auto node = MessageQueue::Node::tryCreate();
    if (!node)
        return Bun::Bindgen::nativeAllocationFailure();
    RefPtr<StringImpl> text;
    if (message.is8Bit()) {
        std::span<Latin1Character> characters;
        text = StringImpl::tryCreateUninitialized(message.length(), characters);
        if (!text)
            return Bun::Bindgen::nativeAllocationFailure();
        std::copy(message.span8().begin(), message.span8().end(), characters.begin());
    } else {
        std::span<char16_t> characters;
        text = StringImpl::tryCreateUninitialized(message.length(), characters);
        if (!text)
            return Bun::Bindgen::nativeAllocationFailure();
        std::copy(message.span16().begin(), message.span16().end(), characters.begin());
    }
    node->message = MessageQueue::ErrorMessage { String { WTF::move(text) } };
    enqueueToParent(WTF::move(node));
    return {};
}

ExceptionOr<bool> Worker::dispatchErrorWithValue(Zig::GlobalObject* workerGlobalObject, JSValue value)
{
    auto& vm = workerGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto node = MessageQueue::Node::tryCreate();
    if (!node)
        return Exception { OutOfMemoryError };
    Vector<RefPtr<MessagePort>> ports;
    auto serialized = SerializedScriptValue::prepare(*workerGlobalObject, value, {}, ports);
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    vm.hasExceptionsAfterHandlingTraps();
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (serialized.hasException()) {
        auto exception = serialized.releaseException();
        if (exception.code() == DataCloneError)
            return false;
        return exception;
    }
    ASSERT(ports.isEmpty());
    auto prepared = serialized.releaseReturnValue();
    auto validation = prepared.validateTransfers();
    if (validation.hasException())
        return validation.releaseException();
    node->message = MessageQueue::ErrorValue { prepared.commit(vm) };
    enqueueToParent(WTF::move(node));
    return true;
}

bool Worker::dispatchExit(int32_t exitCode)
{
    Ref delivery { *m_exitDelivery };
    return delivery->notify(exitCode);
}

void Worker::finishExit(int32_t exitCode, bool shouldDispatchEvent)
{
    if (m_exitFinalized.load())
        return;
    if (shouldDispatchEvent) {
        m_pendingExitCode = exitCode;
        if (auto* context = scriptExecutionContext()) {
            drainToParent(*context);
            return;
        }
    }
    finalizeExit(exitCode, false);
}

void Worker::finalizeExit(int32_t exitCode, bool shouldDispatchEvent)
{
    if (m_exitFinalized.exchange(true))
        return;

    Ref protectedThis { *this };
    m_pendingExitCode.reset();
    auto releaseThreadReference = makeScopeExit([&] {
        m_state.store(State::Closed);
        Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerReleaseParentPollRef(impl_);
        deref();
    });
    closeLifecycleDelivery();
    m_toWorker.close();
    m_toParent.close();
    closeParentMessageDelivery();
    auto abandonedTasks = [&]() {
        Locker lock(m_pendingTasksMutex);
        m_state.store(State::Closing);
        return std::exchange(m_pendingTasks, {});
    }();
    abandonedTasks.clear();
    if (shouldDispatchEvent && hasEventListeners(eventNames().closeEvent)) {
        auto event = CloseEvent::tryCreate(exitCode == 0, static_cast<unsigned short>(exitCode), exitCode == 0 ? "Worker terminated normally"_s : "Worker exited abnormally"_s);
        if (!event) {
            if (auto* context = scriptExecutionContext()) {
                auto* global = context->globalObject();
                auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
                if (!scope.exception()) {
                    auto throwScope = DECLARE_THROW_SCOPE(global->vm());
                    throwOutOfMemoryError(global, throwScope);
                }
                if (auto* exception = scope.exception())
                    reportException(global, exception);
            }
            return;
        }
        EventTargetWithInlineData::dispatchEvent(*event);
    }
}

static void teardownThreadJSCVM(Zig::GlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    JSC::JSLockHolder lock(vm);
    vm.setHasTerminationRequest();

    {
        auto scope = DECLARE_THROW_SCOPE(vm);
        globalObject->moduleLoader()->clearAll();
        globalObject->requireMap()->clear(globalObject);
        scope.exception(); // TODO: handle or assert none?
        vm.deleteAllCode(JSC::DeleteAllCodeEffort::PreventCollectionAndDeleteAllCode);
        gcUnprotect(globalObject);
        globalObject = nullptr;
    }

    vm.heap.collectNow(JSC::Sync, JSC::CollectionScope::Full);

    vm.derefSuppressingSaferCPPChecking();
}

static JSValue initializeNodeWorkerData(Zig::GlobalObject* globalObject)
{
    VM& vm = globalObject->vm();

    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    JSValue workerData = jsNull();
    JSMap* environmentData = nullptr;

    if (auto worker = Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerGetParent(globalObject)) {
        auto& options = (*worker)->options();
        auto ports = MessagePort::entanglePorts(*globalObject->scriptExecutionContext(), options.dataMessagePorts.mutableSpan());
        RETURN_IF_EXCEPTION(scope, {});
        if (ports.hasException()) {
            propagateException(*globalObject, scope, ports.releaseException());
            return {};
        }
        RefPtr<WebCore::SerializedScriptValue> serialized = WTF::move(options.workerDataAndEnvironmentData);
        JSValue deserialized = serialized->deserialize(*globalObject, globalObject, ports.releaseReturnValue());
        RETURN_IF_EXCEPTION(scope, {});
        // Should always be set to an Array of length 2 in the constructor in JSWorker.cpp
        auto* pair = uncheckedDowncast<JSArray>(deserialized);
        ASSERT(pair->length() == 2);
        ASSERT(pair->canGetIndexQuickly(0u));
        ASSERT(pair->canGetIndexQuickly(1u));
        workerData = pair->getIndexQuickly(0);
        RETURN_IF_EXCEPTION(scope, {});
        auto environmentDataValue = pair->getIndexQuickly(1);
        // it might not be a Map if the parent had not set up environmentData yet
        environmentData = environmentDataValue ? dynamicDowncast<JSMap>(environmentDataValue) : nullptr;
        RETURN_IF_EXCEPTION(scope, {});
    }
    if (!environmentData) {
        environmentData = JSMap::create(vm, globalObject->mapStructure());
        RETURN_IF_EXCEPTION(scope, {});
    }
    ASSERT(environmentData);
    globalObject->setNodeWorkerEnvironmentData(environmentData);
    return workerData;
}

} // namespace WebCore

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFunctions_initializeWorkerData(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFunctions_initializeWorkerData_Arguments&)
{
    return WebCore::initializeNodeWorkerData(static_cast<Zig::GlobalObject*>(&context.globalObject));
}

double Bun::Bindgen::Cpp::bunBindgenCpp_WebCoreFunctions_workerThreadId(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_WebCoreFunctions_workerThreadId_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    if (auto worker = Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerGetParent(globalObject))
        return static_cast<double>((*worker)->clientIdentifier() - 1);
    return 0;
}

JSC::JSValue Bun::Bindgen::Cpp::bunBindgenCpp_WebCoreFunctions_workerEnvironmentData(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_WebCoreFunctions_workerEnvironmentData_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    if (auto* environmentData = globalObject->nodeWorkerEnvironmentData())
        return environmentData;

    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* environmentData = JSC::JSMap::create(globalObject->vm(), globalObject->mapStructure());
    RETURN_IF_EXCEPTION(scope, {});
    globalObject->setNodeWorkerEnvironmentData(environmentData);
    return environmentData;
}

std::optional<JSC::JSValue> Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFunctions_receiveMessageOnPort(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFunctions_receiveMessageOnPort_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    if (args.port.is_broadcast_channel())
        return std::nullopt;
    auto* messagePort = WTF::dynamicDowncast<WebCore::JSMessagePort>(args.port.message_port());
    RELEASE_ASSERT(messagePort);
    return messagePort->wrapped().tryTakeMessage(globalObject);
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFunctions_postMessage(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFunctions_postMessage_Arguments& args)
{
    auto* globalObject = dynamicDowncast<Zig::GlobalObject>(&context.globalObject);
    if (!globalObject) [[unlikely]]
        return;

    auto worker = Bun::Bindgen::ZigExports::bunBindgenZig_WebWorkerEngine_webWorkerGetParent(globalObject);
    if (!worker)
        return;

    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto options = Bun::Bindgen::structuredSerializeOptionsFromBinding(*globalObject, args.transfer);
    RETURN_IF_EXCEPTION(scope, );
    RELEASE_ASSERT(options);

    auto node = WebCore::MessageQueue::Node::tryCreate();
    if (!node) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }
    auto prepared = WebCore::MessagePort::prepareMessage(*globalObject, args.value, WTF::move(options->transfer));
    RETURN_IF_EXCEPTION(scope, );
    if (prepared.hasException()) {
        WebCore::propagateException(*globalObject, scope, prepared.releaseException());
        return;
    }
    auto message = prepared.releaseReturnValue().commit(*globalObject);
    RETURN_IF_EXCEPTION(scope, );
    if (message.hasException()) {
        WebCore::propagateException(*globalObject, scope, message.releaseException());
        return;
    }
    node->message = message.releaseReturnValue();
    (*worker)->enqueueToParent(WTF::move(node));
}

void Bun::Bindgen::Engine::bunBindgenEngine_jsc_thread_teardown_teardownThreadJSCVM(
    const Bun::Bindgen::Engine::BunBindgenEngine_jsc_thread_teardown_teardownThreadJSCVM_Arguments& args)
{
    WebCore::teardownThreadJSCVM(args.globalObject);
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebWorkerEngine_webWorkerDispatchExit(
    const Bun::Bindgen::Engine::BunBindgenEngine_WebWorkerEngine_webWorkerDispatchExit_Arguments& args)
{
    args.worker->dispatchExit(args.exitCode);
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebWorkerEngine_webWorkerFinishExit(
    const Bun::Bindgen::Engine::BunBindgenEngine_WebWorkerEngine_webWorkerFinishExit_Arguments& args)
{
    args.worker->finishExit(args.exitCode, args.dispatchEvent);
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebWorkerEngine_webWorkerDispatchOnline(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebWorkerEngine_webWorkerDispatchOnline_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto result = args.worker->dispatchOnline(uncheckedDowncast<Zig::GlobalObject>(&context.globalObject));
    RETURN_IF_EXCEPTION(scope, void());
    if (result.hasException())
        WebCore::propagateException(context.globalObject, scope, result.releaseException());
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebWorkerEngine_webWorkerFireEarlyMessages(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebWorkerEngine_webWorkerFireEarlyMessages_Arguments& args)
{
    args.worker->fireEarlyMessages(uncheckedDowncast<Zig::GlobalObject>(&context.globalObject));
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebWorkerEngine_webWorkerDispatchError(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_WebWorkerEngine_webWorkerDispatchError_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    WebCore::ErrorEvent::Init init;
    init.message = args.message;
    init.error = args.error;
    init.cancelable = false;
    init.bubbles = false;

    WebCore::ErrorEvent::dispatch(globalObject->globalEventScope.get(), init, WebCore::EventIsTrusted::Yes);
    RETURN_IF_EXCEPTION(scope, void());
    if (args.worker->options().kind == WebCore::WorkerOptions::Kind::Node) {
        auto result = args.worker->dispatchErrorWithValue(globalObject, args.error);
        RETURN_IF_EXCEPTION(scope, void());
        if (result.hasException()) {
            WebCore::propagateException(*globalObject, scope, result.releaseException());
            return;
        }
        if (result.releaseReturnValue())
            return;
    }
    if (!args.worker->dispatchErrorWithMessage(args.message))
        throwOutOfMemoryError(globalObject, scope);
}
