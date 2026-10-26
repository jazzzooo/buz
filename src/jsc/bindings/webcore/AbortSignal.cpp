/*
 * Copyright (C) 2017-2023 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "AbortSignal.h"
#include "SchemaBindings.h"

#include "AbortController.h"
#include "JSDOMWrapperCache.h"
#include "WebCoreJSClientData.h"
#include "DOMException.h"
// #include "DOMTimer.h"
#include "Event.h"
#include "EventNames.h"
#include "JSDOMException.h"
#include "JSDOMExceptionHandling.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "ScriptExecutionContext.h"
#include "WebCoreOpaqueRoot.h"
#include "wtf/DebugHeap.h"
#include <wtf/TZoneMallocInlines.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/CallData.h>
#include <JavaScriptCore/JSCast.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/WeakInlines.h>
#include <limits>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AbortSignal);

Ref<AbortSignal> AbortSignal::create(ScriptExecutionContext* context)
{
    return adoptRef(*new AbortSignal(context));
}

// https://dom.spec.whatwg.org/#dom-abortsignal-abort
RefPtr<AbortSignal> AbortSignal::abort(JSDOMGlobalObject& globalObject, ScriptExecutionContext& context, JSC::JSValue reason)
{
    ASSERT(reason);
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    if (reason.isUndefined()) {
        reason = toJS(&globalObject, &globalObject, DOMException::create(ExceptionCode::AbortError));
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return adoptRef(*new AbortSignal(&context, Aborted::Yes, reason));
}

// https://dom.spec.whatwg.org/#dom-abortsignal-timeout
Ref<AbortSignal> AbortSignal::timeout(ScriptExecutionContext& context, uint64_t milliseconds)
{
    auto signal = adoptRef(*new AbortSignal(&context));
    signal->ref();
    signal->m_timeout = Bun::Bindgen::ZigExports::bunBindgenZig_abort_signals_abortSignalTimeoutCreate(bunVM(context.vm()), signal.ptr(), milliseconds);
    ASSERT(signal->m_timeout);
    return signal;
}

RefPtr<AbortSignal> AbortSignal::any(JSDOMGlobalObject& globalObject, ScriptExecutionContext& context, const Vector<RefPtr<AbortSignal>>& signals)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    Ref resultSignal = AbortSignal::create(&context);

    auto abortedSignalIndex = signals.findIf([](auto& signal) { return signal->aborted(); });
    if (abortedSignalIndex != notFound) {
        auto reason = signals[abortedSignalIndex]->jsReason(globalObject);
        RETURN_IF_EXCEPTION(scope, nullptr);
        scope.release();
        resultSignal->signalAbort(reason);
        return resultSignal;
    }

    resultSignal->markAsDependent();
    for (auto& signal : signals)
        resultSignal->addSourceSignal(*signal);

    return resultSignal;
}

AbortSignal::AbortSignal(ScriptExecutionContext* context, Aborted aborted, JSC::JSValue reason)
    : ContextDestructionObserver(context)
    , m_reason(reason)
    , m_flags(aborted == Aborted::Yes ? static_cast<uint8_t>(AbortSignalFlags::Aborted) : 0)
{
    ASSERT(reason);
}

AbortSignal::~AbortSignal()
{
    // Self-signal listeners must not retain this object during base-class teardown.
    if (auto* impl = weakPtrFactory().impl())
        impl->clear();
    while (m_firstListenerAbortAlgorithm)
        detachEventListenerAbortAlgorithm(*m_firstListenerAbortAlgorithm);

    ASSERT(!m_timeout);
}

JSValue AbortSignal::jsReason(JSC::JSGlobalObject& globalObject)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    JSValue existingValue = m_reason.getValue(jsUndefined());
    if (existingValue.isUndefined()) {
        if (m_commonReason != CommonAbortReason::None) {
            existingValue = toJS(&globalObject, m_commonReason);
            RETURN_IF_EXCEPTION(scope, {});
            m_commonReason = CommonAbortReason::None;
            setReason(globalObject.vm(), existingValue);
        }
    }

    return existingValue;
}

void AbortSignal::addSourceSignal(AbortSignal& signal)
{
    if (signal.isDependent()) {
        for (Ref sourceSignal : signal.sourceSignals())
            addSourceSignal(sourceSignal);
        return;
    }
    ASSERT(!signal.aborted());
    ASSERT(signal.sourceSignals().isEmptyIgnoringNullReferences());
    m_sourceSignals.add(signal);
    signal.addDependentSignal(*this);
}

void AbortSignal::addDependentSignal(AbortSignal& signal)
{
    m_dependentSignals.add(signal);
}

void AbortSignal::cancelTimer()
{
    if (auto timeout = std::exchange(m_timeout, nullptr)) {
        Bun::Bindgen::ZigExports::bunBindgenZig_abort_signals_abortSignalTimeoutDestroy(timeout);
    }
}

void AbortSignal::setReason(JSC::VM& vm, JSC::JSValue reason)
{
    ASSERT(reason);
    m_reason.setWeakly(reason);
    auto* worlds = static_cast<JSVMClientData*>(vm.clientData)->wrapperWorlds();
    writeBarrierForWrappers(vm, worlds, *this);
    // Controllers trace the reason even before a signal wrapper exists.
    if (m_controller)
        writeBarrierForWrappers(vm, worlds, *m_controller);
}

void AbortSignal::markAborted(JSC::JSValue reason)
{
    applyFlags(static_cast<uint8_t>(AbortSignalFlags::Aborted) | static_cast<uint8_t>(AbortSignalFlags::IsFiringEventListeners));
    m_sourceSignals.clear();

    setReason(scriptExecutionContext()->vm(), reason);

    cancelTimer();
}

void AbortSignal::runAbortSteps()
{
    auto reason = m_reason.getValue();
    ASSERT(reason);

    auto listeners = std::exchange(m_nativeListeners, {});
    auto* globalObject = scriptExecutionContext()->jsGlobalObject();
    RELEASE_ASSERT(globalObject);
    for (auto* listener : listeners)
        Bun::Bindgen::ZigExports::bunBindgenZig_abort_signals_abortSignalRunListener(
            globalObject,
            static_cast<BunBindgenAbortSignalListener*>(listener),
            reason);

    while (m_firstListenerAbortAlgorithm) {
        Ref registration { *m_firstListenerAbortAlgorithm };
        RefPtr target = registration->m_abortTarget.get();
        AtomString eventType = registration->m_abortEventType;
        detachEventListenerAbortAlgorithm(registration);
        if (target)
            target->removeEventListener(eventType, registration->callback(), registration->useCapture());
    }

    {
        Locker locker { m_abortAlgorithmsLock };
        ASSERT(m_runningAbortAlgorithms.isEmpty());
        m_runningAbortAlgorithms = std::exchange(m_abortAlgorithms, {});
    }
    size_t algorithmIndex = 0;
    while (true) {
        JSC::JSObject* callback;
        {
            Locker locker { m_abortAlgorithmsLock };
            if (algorithmIndex == m_runningAbortAlgorithms.size())
                break;
            callback = m_runningAbortAlgorithms[algorithmIndex++].second.get();
        }
        if (callback)
            invokeAbortAlgorithm(*callback, reason);
    }
    {
        Locker locker { m_abortAlgorithmsLock };
        m_runningAbortAlgorithms.clear();
    }

    // 3. Fire an event named abort at signal.
    if (hasEventListeners(eventNames().abortEvent))
        dispatchSimpleEvent(eventNames().abortEvent);
    setIsFiringEventListeners(false);
}

// https://dom.spec.whatwg.org/#abortsignal-signal-abort
void AbortSignal::signalAbort(JSC::JSValue reason)
{
    // 1. If signal’s aborted flag is set, then return.
    if (aborted())
        return;

    Ref protectedThis { *this };

    // 2. Set signal’s abort reason to reason if it is given; otherwise to a new "AbortError" DOMException.
    markAborted(reason);

    RefPtr<AbortSignal> dependentSignalsToAbort;
    AbortSignal* lastDependentSignal = nullptr;

    for (Ref dependentSignal : std::exchange(m_dependentSignals, {})) {
        if (!dependentSignal->aborted()) {
            ASSERT(!dependentSignal->m_nextDependentToAbort);
            dependentSignal->markAborted(reason);
            if (lastDependentSignal)
                lastDependentSignal->m_nextDependentToAbort = dependentSignal.ptr();
            else
                dependentSignalsToAbort = dependentSignal.ptr();
            lastDependentSignal = dependentSignal.ptr();
        }
    }

    // 5. Run the abort steps
    runAbortSteps();

    // 6. For each dependentSignal of dependentSignalsToAbort, run the abort steps for dependentSignal.
    while (dependentSignalsToAbort) {
        Ref dependentSignal = dependentSignalsToAbort.releaseNonNull();
        dependentSignalsToAbort = std::exchange(dependentSignal->m_nextDependentToAbort, nullptr);
        dependentSignal->runAbortSteps();
    }

    JSC::ensureStillAliveHere(reason);
}

void AbortSignal::signalAbort(JSC::JSGlobalObject* globalObject, CommonAbortReason reason)
{
    // 1. If signal's aborted flag is set, then return.
    if (aborted())
        return;

    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto value = toJS(globalObject, reason);
    RETURN_IF_EXCEPTION(scope, void());
    m_commonReason = reason;
    scope.release();
    signalAbort(value);
}

void AbortSignal::removeNativeListener(void* listener)
{
    m_nativeListeners.removeAll(listener);
    eventListenersDidChange();
}

void AbortSignal::eventListenersDidChange()
{
    bool hasListeners = hasEventListeners(eventNames().abortEvent) or !m_nativeListeners.isEmpty();
    setHasAbortEventListener(hasListeners);

    // When a timeout signal loses all observers (no JS listeners, no native
    // callbacks, no algorithms, no dependent signals), there is nothing left
    // to notify when the timer fires.  Cancel the timer and release the extra
    // ref that timeout() took to keep the signal alive, so the C++ object can
    // be destroyed normally.
    if (!hasListeners && m_timeout && !aborted()
        && !m_firstListenerAbortAlgorithm && !hasPendingActivity()
        && m_dependentSignals.isEmptyIgnoringNullReferences()) {
        bool shouldCancel;
        {
            Locker locker { m_abortAlgorithmsLock };
            shouldCancel = m_abortAlgorithms.isEmpty();
        }
        // Timer teardown may release the last reference to this signal.
        if (shouldCancel)
            cancelTimer();
    }
}

void AbortSignal::invokeAbortAlgorithm(JSC::JSObject& callback, JSC::JSValue reason)
{
    auto& globalObject = *uncheckedDowncast<JSDOMGlobalObject>(callback.globalObject());
    auto* context = globalObject.scriptExecutionContext();
    if (!context || context->activeDOMObjectsAreSuspended() || context->activeDOMObjectsAreStopped())
        return;

    auto& vm = globalObject.vm();
    JSC::JSLockHolder lock(vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(reason);
    if (arguments.hasOverflowed()) {
        auto throwScope = DECLARE_THROW_SCOPE(vm);
        JSC::throwOutOfMemoryError(&globalObject, throwScope);
    }
    if (!scope.exception()) {
        auto callData = JSC::getCallData(&callback);
        RELEASE_ASSERT(callData.type != JSC::CallData::Type::None);
        JSC::profiledCall(&globalObject, JSC::ProfilingReason::Other, &callback, callData, JSC::jsUndefined(), arguments);
    }
    if (auto* exception = scope.exception())
        reportException(&globalObject, exception);
    JSC::ensureStillAliveHere(&callback);
}

Bun::Bindgen::NativeAllocationResult<uint32_t> AbortSignal::addAbortAlgorithmToSignal(AbortSignal& signal, JSC::JSObject& callback)
{
    if (signal.aborted()) {
        auto& globalObject = *signal.scriptExecutionContext()->jsGlobalObject();
        auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
        auto reason = signal.jsReason(globalObject);
        RETURN_IF_EXCEPTION(scope, 0);
        scope.release();
        invokeAbortAlgorithm(callback, reason);
        return 0;
    }
    if (signal.m_algorithmIdentifier == std::numeric_limits<uint32_t>::max())
        return Bun::Bindgen::nativeAllocationFailure();
    const uint32_t identifier = signal.m_algorithmIdentifier + 1;
    auto entry = std::make_pair(identifier, JSC::Weak<JSC::JSObject> { &callback });
    {
        Locker locker { signal.m_abortAlgorithmsLock };
        if (!signal.m_abortAlgorithms.tryAppend(WTF::move(entry)))
            return Bun::Bindgen::nativeAllocationFailure();
        signal.m_algorithmIdentifier = identifier;
    }
    auto& vm = callback.vm();
    auto* worlds = static_cast<JSVMClientData*>(vm.clientData)->wrapperWorlds();
    writeBarrierForWrappers(vm, worlds, signal);
    JSC::ensureStillAliveHere(&callback);
    return identifier;
}

void AbortSignal::removeAbortAlgorithmFromSignal(AbortSignal& signal, uint32_t algorithmIdentifier)
{
    Ref protectedSignal { signal };
    JSC::Weak<JSC::JSObject> removed;
    bool found = false;
    {
        Locker locker { signal.m_abortAlgorithmsLock };
        for (size_t i = 0; i < signal.m_abortAlgorithms.size(); ++i) {
            if (signal.m_abortAlgorithms[i].first != algorithmIdentifier)
                continue;
            removed = WTF::move(signal.m_abortAlgorithms[i].second);
            signal.m_abortAlgorithms.removeAt(i);
            found = true;
            break;
        }
    }
    if (found)
        signal.eventListenersDidChange();
}

void AbortSignal::addEventListenerAbortAlgorithm(RegisteredEventListener& registration, EventTarget& target, const AtomString& eventType)
{
    ASSERT(!aborted());
    ASSERT(!registration.m_wasRemoved);
    ASSERT(!registration.m_abortSignal);
    ASSERT(!registration.m_abortPrevious && !registration.m_abortNext);

    auto signal = WeakPtr { *this };
    auto weakTarget = WeakPtr { target };
    registration.m_abortSignal = WTF::move(signal);
    registration.m_abortTarget = WTF::move(weakTarget);
    registration.m_abortEventType = eventType;
    registration.m_abortPrevious = m_lastListenerAbortAlgorithm;
    if (m_lastListenerAbortAlgorithm)
        m_lastListenerAbortAlgorithm->m_abortNext = &registration;
    else
        m_firstListenerAbortAlgorithm = &registration;
    m_lastListenerAbortAlgorithm = &registration;
}

void AbortSignal::detachEventListenerAbortAlgorithm(RegisteredEventListener& registration)
{
    if (registration.m_abortPrevious)
        registration.m_abortPrevious->m_abortNext = registration.m_abortNext;
    else {
        ASSERT(m_firstListenerAbortAlgorithm == &registration);
        m_firstListenerAbortAlgorithm = registration.m_abortNext;
    }
    if (registration.m_abortNext)
        registration.m_abortNext->m_abortPrevious = registration.m_abortPrevious;
    else {
        ASSERT(m_lastListenerAbortAlgorithm == &registration);
        m_lastListenerAbortAlgorithm = registration.m_abortPrevious;
    }
    registration.m_abortPrevious = nullptr;
    registration.m_abortNext = nullptr;
    registration.m_abortSignal = nullptr;
    registration.m_abortTarget = nullptr;
    registration.m_abortEventType = AtomString {};
}

void AbortSignal::removeEventListenerAbortAlgorithm(RegisteredEventListener& registration)
{
    Ref protectedThis { *this };
    ASSERT(registration.m_abortSignal.get() == this);
    detachEventListenerAbortAlgorithm(registration);
    eventListenersDidChange();
}

void AbortSignal::throwIfAborted(JSC::JSGlobalObject& lexicalGlobalObject)
{
    if (!aborted())
        return;

    Ref vm = lexicalGlobalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto reason = jsReason(lexicalGlobalObject);
    RETURN_IF_EXCEPTION(scope, void());
    throwException(&lexicalGlobalObject, scope, reason);
}

WebCoreOpaqueRoot root(AbortSignal* signal)
{
    return WebCoreOpaqueRoot { signal };
}

size_t AbortSignal::memoryCost() const
{
    return sizeof(AbortSignal) + m_nativeListeners.sizeInBytes() + m_abortAlgorithms.sizeInBytes() + m_runningAbortAlgorithms.sizeInBytes() + m_sourceSignals.capacity() + m_dependentSignals.capacity();
}

template<typename Visitor>
void AbortSignal::visitAbortAlgorithms(Visitor& visitor)
{
    Locker locker { m_abortAlgorithmsLock };
    for (auto& pair : m_abortAlgorithms)
        visitor.append(pair.second);
    for (auto& pair : m_runningAbortAlgorithms)
        visitor.append(pair.second);
}

template void AbortSignal::visitAbortAlgorithms(JSC::AbstractSlotVisitor&);
template void AbortSignal::visitAbortAlgorithms(JSC::SlotVisitor&);

} // namespace WebCore
