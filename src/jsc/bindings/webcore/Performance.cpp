/*
 * Copyright (C) 2010 Google Inc. All rights reserved.
 * Copyright (C) 2012 Intel Inc. All rights reserved.
 * Copyright (C) 2016 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "Performance.h"

// #include "Document.h"
// #include "DocumentLoader.h"
#include "Event.h"
// #include "EventLoop.h"
#include "EventNames.h"
#include "JSDOMExceptionHandling.h"
#include "NativeEventLoopTarget.h"
// #include "LocalFrame.h"
#include "PerformanceEntry.h"
#include "PerformanceMarkOptions.h"
#include "PerformanceMeasureOptions.h"
// #include "PerformanceNavigation.h"
// #include "PerformanceNavigationTiming.h"
#include "PerformanceObserver.h"
// #include "PerformancePaintTiming.h"
#include "PerformanceResourceTiming.h"
#include "PerformanceUserTiming.h"
// #include "ResourceResponse.h"
#include "ScriptExecutionContext.h"
#include <wtf/FastMalloc.h>
#include <wtf/Scope.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include "BunClientData.h"
#include "SchemaBindings.h"

namespace WebCore {

class Performance::ObserverDeliveryTarget final : public Bun::NativeEventLoopTarget {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(ObserverDeliveryTarget);

public:
    static RefPtr<ObserverDeliveryTarget> tryCreate()
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(ObserverDeliveryTarget)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) ObserverDeliveryTarget);
    }

    bool isPending() const { return !!m_pending; }
    bool isStopped() const { return m_stopped; }

    void prepare(Performance& performance)
    {
        ASSERT(!m_pending && !m_stopped);
        m_pending = &performance;
    }

    void run(JSC::JSGlobalObject*) noexcept final
    {
        auto performance = std::exchange(m_pending, nullptr);
        if (!performance)
            return;
        if (!performance->scriptExecutionContext())
            return;
        if (!performance->deliverObservers()) {
            auto* context = performance->scriptExecutionContext();
            if (!context)
                return;
            auto* globalObject = context->globalObject();
            if (!globalObject)
                return;
            auto scope = DECLARE_TOP_EXCEPTION_SCOPE(globalObject->vm());
            if (!scope.exception()) {
                auto throwScope = DECLARE_THROW_SCOPE(globalObject->vm());
                JSC::throwOutOfMemoryError(globalObject, throwScope);
            }
            if (auto* exception = scope.exception())
                reportException(globalObject, exception);
        }
    }

    void stop() noexcept final
    {
        m_stopped = true;
        m_pending = nullptr;
    }

private:
    RefPtr<Performance> m_pending;
    bool m_stopped { false };
};

constexpr Seconds highTimePrecision { 20_us };
static Seconds timePrecision { 1_ms };

RefPtr<Performance> Performance::tryCreate(ScriptExecutionContext* context, MonotonicTime monotonicTimeOrigin, WallTime wallTimeOrigin)
{
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(Performance)).getValue(allocation))
        return nullptr;
    return adoptRef(*new (NotNull, allocation) Performance(context, monotonicTimeOrigin, wallTimeOrigin));
}

Performance::Performance(ScriptExecutionContext* context, MonotonicTime monotonicTimeOrigin, WallTime wallTimeOrigin)
    : ContextDestructionObserver(context)
    // , m_resourceTimingBufferFullTimer(*this, &Performance::resourceTimingBufferFullTimerFired) // FIXME: Migrate this to the event loop as well. https://bugs.webkit.org/show_bug.cgi?id=229044
    , m_monotonicTimeOrigin(monotonicTimeOrigin)
    , m_wallTimeOrigin(wallTimeOrigin)
{
    ASSERT(m_monotonicTimeOrigin);
}

Performance::~Performance()
{
    ASSERT(!m_firstObserver && !m_lastObserver);
    closeObserverDelivery();
}

void Performance::contextDestroyed(ScriptExecutionContext&)
{
    Ref protectedThis { *this };
    closeObserverDelivery();
}

DOMHighResTimeStamp Performance::now() const
{
    auto nowNano = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_readOriginTimer(bunVM(scriptExecutionContext()->vm()));
    return static_cast<double>(nowNano) / 1000000.0;
}

DOMHighResTimeStamp Performance::timeOrigin() const
{
    return m_wallTimeOrigin.secondsSinceEpoch().milliseconds();
}

Seconds Performance::reduceTimeResolution(Seconds seconds)
{
    double resolution = timePrecision.seconds();
    double reduced = std::floor(seconds.seconds() / resolution) * resolution;
    return Seconds(reduced);
}

void Performance::allowHighPrecisionTime()
{
    timePrecision = highTimePrecision;
}

Seconds Performance::timeResolution()
{
    return timePrecision;
}

// PerformanceNavigation* Performance::navigation()
// {
//     if (!is<Document>(scriptExecutionContext()))
//         return nullptr;

//     ASSERT(isMainThread());
//     if (!m_navigation)
//         m_navigation = PerformanceNavigation::create(downcast<Document>(*scriptExecutionContext()).domWindow());
//     return m_navigation.get();
// }

Bun::Bindgen::NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>> Performance::getEntries() const
{
    return getEntriesByType(String {});
}

Bun::Bindgen::NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>> Performance::getEntriesByType(const String& entryType) const
{
    Vector<RefPtr<PerformanceEntry>> entries;
    if (!tryAppendBufferedEntriesByType(entryType, entries))
        return Bun::Bindgen::nativeAllocationFailure();

    std::sort(entries.begin(), entries.end(), PerformanceEntry::startTimeCompareLessThan);
    return entries;
}

size_t Performance::memoryCost() const
{
    size_t size = sizeof(Performance);
    size += m_resourceTimingBuffer.size() * sizeof(PerformanceResourceTiming);
    if (m_userTiming) {
        size += m_userTiming->memoryCost();
    }
    return size;
}

Bun::Bindgen::NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>> Performance::getEntriesByName(const String& name, const String& entryType) const
{
    Vector<RefPtr<PerformanceEntry>> entries;

    if (entryType.isNull() || entryType == "resource"_s) {
        for (auto& resource : m_resourceTimingBuffer) {
            if (resource->name() == name && !entries.tryAppend(resource))
                return Bun::Bindgen::nativeAllocationFailure();
        }
    }

    if (m_userTiming) {
        if ((entryType.isNull() || entryType == "mark"_s) && !m_userTiming->tryAppendMarks(entries, name))
            return Bun::Bindgen::nativeAllocationFailure();
        if ((entryType.isNull() || entryType == "measure"_s) && !m_userTiming->tryAppendMeasures(entries, name))
            return Bun::Bindgen::nativeAllocationFailure();
    }

    std::sort(entries.begin(), entries.end(), PerformanceEntry::startTimeCompareLessThan);
    return entries;
}

bool Performance::tryAppendBufferedEntriesByType(const String& entryType, Vector<RefPtr<PerformanceEntry>>& entries) const
{
    if ((entryType.isNull() || entryType == "resource"_s) && !entries.tryAppend(m_resourceTimingBuffer.span()))
        return false;

    if (m_userTiming) {
        if ((entryType.isNull() || entryType == "mark"_s) && !m_userTiming->tryAppendMarks(entries))
            return false;
        if ((entryType.isNull() || entryType == "measure"_s) && !m_userTiming->tryAppendMeasures(entries))
            return false;
    }
    return true;
}

void Performance::clearResourceTimings()
{
    m_resourceTimingBuffer.clear();
    m_resourceTimingBufferFullFlag = false;
}

void Performance::setResourceTimingBufferSize(unsigned size)
{
    m_resourceTimingBufferSize = size;
    m_resourceTimingBufferFullFlag = false;
}

// void Performance::reportFirstContentfulPaint()
// {
//     ASSERT(!m_firstContentfulPaint);
//     m_firstContentfulPaint = PerformancePaintTiming::createFirstContentfulPaint(now());
//     queueEntry(*m_firstContentfulPaint);
// }

// void Performance::addNavigationTiming(DocumentLoader& documentLoader, Document& document, CachedResource& resource, const DocumentLoadTiming& timing, const NetworkLoadMetrics& metrics)
// {
//     ASSERT(document.settings().performanceNavigationTimingAPIEnabled());
//     m_navigationTiming = PerformanceNavigationTiming::create(m_timeOrigin, resource, timing, metrics, document.eventTiming(), document.securityOrigin(), documentLoader.triggeringAction().type());
// }

// void Performance::navigationFinished(const NetworkLoadMetrics& metrics)
// {
//     if (!m_navigationTiming)
//         return;
//     m_navigationTiming->navigationFinished(metrics);

//     queueEntry(*m_navigationTiming);
// }

Bun::Bindgen::NativeAllocationResult<void> Performance::addResourceTiming(ResourceTiming&& resourceTiming)
{
    ASSERT(scriptExecutionContext());

    auto entry = PerformanceResourceTiming::tryCreate(m_monotonicTimeOrigin, WTF::move(resourceTiming));
    if (!entry || !prepareObserverEntry(*entry))
        return Bun::Bindgen::nativeAllocationFailure();

    if (m_waitingForBackupBufferToBeProcessed) {
        if (!m_backupResourceTimingBuffer.tryAppend(WTF::move(entry)))
            return Bun::Bindgen::nativeAllocationFailure();
        return {};
    }

    if (m_resourceTimingBufferFullFlag) {
        // We fired resourcetimingbufferfull event but the author script didn't clear the buffer.
        // Notify performance observers but don't add it to the buffer.
        queueEntry(*entry);
        return {};
    }

    if (isResourceTimingBufferFull()) {
        // ASSERT(!m_resourceTimingBufferFullTimer.isActive());
        if (!m_backupResourceTimingBuffer.tryAppend(WTF::move(entry)))
            return Bun::Bindgen::nativeAllocationFailure();
        m_waitingForBackupBufferToBeProcessed = true;
        // m_resourceTimingBufferFullTimer.startOneShot(0_s);
        return {};
    }

    if (!m_resourceTimingBuffer.tryAppend(entry))
        return Bun::Bindgen::nativeAllocationFailure();
    queueEntry(*entry);
    return {};
}

bool Performance::isResourceTimingBufferFull() const
{
    return m_resourceTimingBuffer.size() >= m_resourceTimingBufferSize;
}

// void Performance::resourceTimingBufferFullTimerFired()
// {
//     ASSERT(scriptExecutionContext());

//     while (!m_backupResourceTimingBuffer.isEmpty()) {
//         auto beforeCount = m_backupResourceTimingBuffer.size();

//         auto backupBuffer = WTF::move(m_backupResourceTimingBuffer);
//         ASSERT(m_backupResourceTimingBuffer.isEmpty());

//         if (isResourceTimingBufferFull()) {
//             m_resourceTimingBufferFullFlag = true;
//             dispatchEvent(Event::create(eventNames().resourcetimingbufferfullEvent, Event::CanBubble::No, Event::IsCancelable::No));
//         }

//         if (m_resourceTimingBufferFullFlag) {
//             for (auto& entry : backupBuffer)
//                 queueEntry(*entry);
//             // Dispatching resourcetimingbufferfull event may have inserted more entries.
//             for (auto& entry : m_backupResourceTimingBuffer)
//                 queueEntry(*entry);
//             m_backupResourceTimingBuffer.clear();
//             break;
//         }

//         // More entries may have added while dispatching resourcetimingbufferfull event.
//         backupBuffer.appendVector(m_backupResourceTimingBuffer);
//         m_backupResourceTimingBuffer.clear();

//         for (auto& entry : backupBuffer) {
//             if (!isResourceTimingBufferFull()) {
//                 m_resourceTimingBuffer.append(entry.copyRef());
//                 queueEntry(*entry);
//             } else
//                 m_backupResourceTimingBuffer.append(entry.copyRef());
//         }

//         auto afterCount = m_backupResourceTimingBuffer.size();

//         if (beforeCount <= afterCount) {
//             m_backupResourceTimingBuffer.clear();
//             break;
//         }
//     }
//     m_waitingForBackupBufferToBeProcessed = false;
// }

ExceptionOr<Ref<PerformanceMark>> Performance::mark(JSC::JSGlobalObject& globalObject, const String& markName, std::optional<PerformanceMarkOptions>&& markOptions)
{
    if (!m_userTiming) {
        m_userTiming = PerformanceUserTiming::tryCreate(*this);
        if (!m_userTiming)
            return Exception { OutOfMemoryError };
    }

    auto mark = m_userTiming->createMark(globalObject, markName, WTF::move(markOptions));
    if (mark.hasException())
        return mark.releaseException();

    if (!prepareObserverEntry(mark.returnValue().get()))
        return Exception { OutOfMemoryError };
    if (!m_userTiming->recordEntry(mark.returnValue().get()))
        return Exception { OutOfMemoryError };
    queueEntry(mark.returnValue().get());
    return mark.releaseReturnValue();
}

void Performance::clearMarks(const String& markName)
{
    if (!m_userTiming)
        return;
    m_userTiming->clearMarks(markName);
}

ExceptionOr<Ref<PerformanceMeasure>> Performance::measure(JSC::JSGlobalObject& globalObject, const String& measureName, std::optional<StartOrMeasureOptions>&& startOrMeasureOptions, const String& endMark)
{
    if (!m_userTiming) {
        m_userTiming = PerformanceUserTiming::tryCreate(*this);
        if (!m_userTiming)
            return Exception { OutOfMemoryError };
    }

    auto measure = m_userTiming->createMeasure(globalObject, measureName, WTF::move(startOrMeasureOptions), endMark);
    if (measure.hasException())
        return measure.releaseException();

    if (!prepareObserverEntry(measure.returnValue().get()))
        return Exception { OutOfMemoryError };
    if (!m_userTiming->recordEntry(measure.returnValue().get()))
        return Exception { OutOfMemoryError };
    queueEntry(measure.returnValue().get());
    return measure.releaseReturnValue();
}

void Performance::clearMeasures(const String& measureName)
{
    if (!m_userTiming)
        return;
    m_userTiming->clearMeasures(measureName);
}

void Performance::removeAllObservers()
{
    Ref protectedThis { *this };
    closeObserverDelivery();
    while (m_firstObserver) {
        Ref observer { *m_firstObserver };
        unregisterPerformanceObserver(observer);
        observer->disassociate();
    }
}

void Performance::registerPerformanceObserver(PerformanceObserver& observer)
{
    ASSERT(observer.m_performance.get() == this);
    ASSERT(!observer.m_registered);
    ASSERT(!observer.m_previousObserver && !observer.m_nextObserver);
    observer.ref();
    observer.m_registered = true;
    observer.m_previousObserver = m_lastObserver;
    if (m_lastObserver)
        m_lastObserver->m_nextObserver = &observer;
    else
        m_firstObserver = &observer;
    m_lastObserver = &observer;
}

void Performance::unregisterPerformanceObserver(PerformanceObserver& observer)
{
    if (!observer.m_registered)
        return;
    ASSERT(observer.m_performance.get() == this);

    if (observer.m_previousObserver)
        observer.m_previousObserver->m_nextObserver = observer.m_nextObserver;
    else
        m_firstObserver = observer.m_nextObserver;
    if (observer.m_nextObserver)
        observer.m_nextObserver->m_previousObserver = observer.m_previousObserver;
    else
        m_lastObserver = observer.m_previousObserver;
    observer.m_previousObserver = nullptr;
    observer.m_nextObserver = nullptr;
    observer.m_registered = false;
    observer.deref();
}

bool Performance::prepareObserverEntry(const PerformanceEntry& entry)
{
    for (auto* observer = m_firstObserver; observer; observer = observer->m_nextObserver) {
        if (observer->typeFilter().contains(entry.performanceEntryType()) && !observer->prepareEntry())
            return false;
    }
    return true;
}

void Performance::queueEntry(PerformanceEntry& entry)
{
    bool shouldScheduleTask = false;
    for (auto* observer = m_firstObserver; observer; observer = observer->m_nextObserver) {
        if (observer->typeFilter().contains(entry.performanceEntryType())) {
            observer->appendPreparedEntry(entry);
            shouldScheduleTask = true;
        }
    }

    if (!shouldScheduleTask)
        return;

    scheduleTaskIfNeeded();
}

ExceptionOr<void> Performance::prepareObserverDelivery()
{
    if (m_observerDeliveryTarget && !m_observerDeliveryTarget->isStopped())
        return {};
    closeObserverDelivery();

    auto* context = scriptExecutionContext();
    if (!context)
        return Exception { InvalidStateError };

    auto target = ObserverDeliveryTarget::tryCreate();
    if (!target)
        return Exception { OutOfMemoryError };
    auto* globalObject = context->globalObject();
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_createNativeEventSignal(globalObject, target.get());
    RETURN_IF_EXCEPTION(scope, Exception { ExistingExceptionError });
    if (!signal)
        return Exception { InvalidStateError };
    m_observerDeliveryTarget = WTF::move(target);
    m_observerDeliverySignal = *signal;
    return {};
}

void Performance::closeObserverDelivery()
{
    auto target = std::exchange(m_observerDeliveryTarget, nullptr);
    if (auto* signal = std::exchange(m_observerDeliverySignal, nullptr))
        Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(signal);
}

void Performance::scheduleTaskIfNeeded()
{
    if (!scriptExecutionContext())
        return;
    ASSERT(m_observerDeliveryTarget && m_observerDeliverySignal);
    if (m_observerDeliveryTarget->isPending() || m_observerDeliveryTarget->isStopped())
        return;
    m_observerDeliveryTarget->prepare(*this);
    if (!Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_notifyNativeEventSignal(m_observerDeliverySignal))
        m_observerDeliveryTarget->stop();
}

Bun::Bindgen::NativeAllocationResult<void> Performance::deliverObservers()
{
    Ref protectedThis { *this };
    Vector<RefPtr<PerformanceObserver>> observers;
    auto releaseDeliveries = makeScopeExit([&] {
        for (auto& observer : observers)
            observer->releaseDelivery();
    });
    for (auto* observer = m_firstObserver; observer; observer = observer->m_nextObserver) {
        if (!observer->tryRetainDelivery())
            return Bun::Bindgen::nativeAllocationFailure();
        if (!observers.tryAppend(observer)) {
            observer->releaseDelivery();
            return Bun::Bindgen::nativeAllocationFailure();
        }
    }
    bool allocationFailed = false;
    for (auto& observer : observers) {
        if (!observer->deliver())
            allocationFailed = true;
    }
    if (allocationFailed)
        return Bun::Bindgen::nativeAllocationFailure();
    return {};
}

} // namespace WebCore
