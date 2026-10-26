/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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

#pragma once

#include "ExceptionOr.h"
#include "PerformanceEntry.h"
#include "Bindgen/NativeResult.h"
#include <JavaScriptCore/Weak.h>
#include <atomic>
#include <span>
#include <wtf/FastMalloc.h>
#include <wtf/OptionSet.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class Performance;

class PerformanceObserver : public RefCounted<PerformanceObserver> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(PerformanceObserver);

public:
    struct Init {
        std::optional<std::span<const String>> entryTypes;
        std::optional<String> type;
        bool buffered;
    };

    static RefPtr<PerformanceObserver> tryCreate(Performance& performance, JSC::JSObject& callback)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(PerformanceObserver)).getValue(allocation))
            return nullptr;
        return adoptRef(*new (NotNull, allocation) PerformanceObserver(performance, callback));
    }

    ~PerformanceObserver();

    void disassociate();

    ExceptionOr<void> observe(const Init&);
    void disconnect();
    Vector<RefPtr<PerformanceEntry>> takeRecords();

    OptionSet<PerformanceEntry::Type> typeFilter() const { return m_typeFilter; }

    Bun::Bindgen::NativeAllocationResult<void> deliver();

    bool isRegistered() const { return m_registered; }
    bool hasPendingDelivery() const { return m_pendingDeliveries.load(std::memory_order_relaxed) != 0; }
    template<typename Visitor> void visitCallback(Visitor&);

private:
    friend class Performance;

    PerformanceObserver(Performance&, JSC::JSObject&);
    void invokeCallback(JSC::JSObject&, std::span<const RefPtr<PerformanceEntry>>);
    bool tryRetainDelivery();
    void releaseDelivery();
    bool prepareEntry();
    void appendPreparedEntry(PerformanceEntry&);

    RefPtr<Performance> m_performance;
    Vector<RefPtr<PerformanceEntry>> m_entriesToDeliver;
    JSC::Weak<JSC::JSObject> m_callback;
    PerformanceObserver* m_previousObserver { nullptr };
    PerformanceObserver* m_nextObserver { nullptr };
    std::atomic<uint32_t> m_pendingDeliveries { 0 };
    OptionSet<PerformanceEntry::Type> m_typeFilter;
    bool m_registered { false };
    bool m_isTypeObserver { false };
};

} // namespace WebCore
