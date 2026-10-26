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

#pragma once

#include "Bindgen/NativeResult.h"
#include "ContextDestructionObserver.h"
// #include "DOMHighResTimeStamp.h"
#include "EventTarget.h"
#include "ExceptionOr.h"
// #include "ReducedResolutionSeconds.h"
#include "ScriptExecutionContext.h"
// #include "Timer.h"
#include <variant>

#include <wtf/FastMalloc.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>
#include <wtf/WallTime.h>

namespace JSC {
class JSGlobalObject;
}

namespace Bun {
struct NativeEventLoopSignal;
}

namespace WebCore {

using ReducedResolutionSeconds = Seconds;
using DOMHighResTimeStamp = double;

class CachedResource;
class Document;
class DocumentLoadTiming;
class DocumentLoader;
class NetworkLoadMetrics;
class PerformanceUserTiming;
class PerformanceEntry;
class PerformanceMark;
class PerformanceMeasure;
class PerformanceNavigation;
class PerformanceNavigationTiming;
class PerformanceObserver;
class PerformancePaintTiming;
class ResourceResponse;
class ResourceTiming;
class ScriptExecutionContext;
struct PerformanceMarkOptions;
struct PerformanceMeasureOptions;

class Performance final : public RefCounted<Performance>, public ContextDestructionObserver, public EventTarget {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Performance);

public:
    static RefPtr<Performance> tryCreate(ScriptExecutionContext*, MonotonicTime monotonicTimeOrigin, WallTime wallTimeOrigin);
    ~Performance();

    DOMHighResTimeStamp now() const;
    DOMHighResTimeStamp timeOrigin() const;
    // ReducedResolutionSeconds nowInReducedResolutionSeconds() const;

    // PerformanceNavigation* navigation();

    Bun::Bindgen::NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>> getEntries() const;
    Bun::Bindgen::NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>> getEntriesByType(const String& entryType) const;
    Bun::Bindgen::NativeAllocationResult<Vector<RefPtr<PerformanceEntry>>> getEntriesByName(const String& name, const String& entryType) const;
    bool tryAppendBufferedEntriesByType(const String& entryType, Vector<RefPtr<PerformanceEntry>>&) const;

    void clearResourceTimings();
    void setResourceTimingBufferSize(unsigned);

    ExceptionOr<Ref<PerformanceMark>> mark(JSC::JSGlobalObject&, const String& markName, std::optional<PerformanceMarkOptions>&&);
    void clearMarks(const String& markName);

    using StartOrMeasureOptions = std::variant<String, PerformanceMeasureOptions>;
    ExceptionOr<Ref<PerformanceMeasure>> measure(JSC::JSGlobalObject&, const String& measureName, std::optional<StartOrMeasureOptions>&&, const String& endMark);
    void clearMeasures(const String& measureName);

    // void addNavigationTiming(DocumentLoader&, Document&, CachedResource&, const DocumentLoadTiming&, const NetworkLoadMetrics&);
    // void navigationFinished(const NetworkLoadMetrics&);
    Bun::Bindgen::NativeAllocationResult<void> addResourceTiming(ResourceTiming&&);

    // void reportFirstContentfulPaint();

    size_t memoryCost() const;

    void removeAllObservers();

    static void allowHighPrecisionTime();
    static Seconds timeResolution();
    static Seconds reduceTimeResolution(Seconds);

    ScriptExecutionContext* scriptExecutionContext() const final { return ContextDestructionObserver::scriptExecutionContext(); }

    using RefCounted::deref;
    using RefCounted::ref;

    // PerformanceNavigationTiming* navigationTiming() { return m_navigationTiming.get(); }

    // EventTargetData* eventTargetData() override;
    // EventTargetData* eventTargetDataConcurrently() override;
    // EventTargetData& ensureEventTargetData() override;

private:
    Performance(ScriptExecutionContext*, MonotonicTime, WallTime);

    void contextDestroyed(ScriptExecutionContext&) override;

    EventTargetInterface eventTargetInterface() const final { return PerformanceEventTargetInterfaceType; }

    void refEventTarget() final { ref(); }
    void derefEventTarget() final { deref(); }

    bool isResourceTimingBufferFull() const;
    // void resourceTimingBufferFullTimerFired();

    void queueEntry(PerformanceEntry&);
    void registerPerformanceObserver(PerformanceObserver&);
    void unregisterPerformanceObserver(PerformanceObserver&);
    bool prepareObserverEntry(const PerformanceEntry&);
    ExceptionOr<void> prepareObserverDelivery();
    void closeObserverDelivery();
    void scheduleTaskIfNeeded();
    Bun::Bindgen::NativeAllocationResult<void> deliverObservers();

    // mutable RefPtr<PerformanceNavigation> m_navigation;

    // https://w3c.github.io/resource-timing/#extensions-performance-interface recommends size of 150.
    Vector<RefPtr<PerformanceEntry>> m_resourceTimingBuffer;
    unsigned m_resourceTimingBufferSize { 150 };

    // Timer m_resourceTimingBufferFullTimer;
    Vector<RefPtr<PerformanceEntry>> m_backupResourceTimingBuffer;

    // https://w3c.github.io/resource-timing/#dfn-resource-timing-buffer-full-flag
    bool m_resourceTimingBufferFullFlag { false };
    bool m_waitingForBackupBufferToBeProcessed { false };
    class ObserverDeliveryTarget;
    RefPtr<ObserverDeliveryTarget> m_observerDeliveryTarget;
    Bun::NativeEventLoopSignal* m_observerDeliverySignal { nullptr };

    MonotonicTime m_monotonicTimeOrigin;
    WallTime m_wallTimeOrigin;

    // RefPtr<PerformanceNavigationTiming> m_navigationTiming;
    // RefPtr<PerformancePaintTiming> m_firstContentfulPaint;
    std::unique_ptr<PerformanceUserTiming> m_userTiming;

    PerformanceObserver* m_firstObserver { nullptr };
    PerformanceObserver* m_lastObserver { nullptr };
    friend class PerformanceObserver;
};

}
