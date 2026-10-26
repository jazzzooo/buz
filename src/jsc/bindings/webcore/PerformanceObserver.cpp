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

#include "config.h"
#include "PerformanceObserver.h"

#include "Performance.h"
#include <JavaScriptCore/WeakInlines.h>
#include <limits>

namespace WebCore {

PerformanceObserver::PerformanceObserver(Performance& performance, JSC::JSObject& callback)
    : m_performance(&performance)
    , m_callback(&callback)
{
}

PerformanceObserver::~PerformanceObserver()
{
    ASSERT(!m_registered && !m_previousObserver && !m_nextObserver && !hasPendingDelivery());
}

bool PerformanceObserver::tryRetainDelivery()
{
    const auto count = m_pendingDeliveries.load(std::memory_order_relaxed);
    if (count == std::numeric_limits<uint32_t>::max())
        return false;
    m_pendingDeliveries.store(count + 1, std::memory_order_relaxed);
    return true;
}

void PerformanceObserver::releaseDelivery()
{
    const auto count = m_pendingDeliveries.fetch_sub(1, std::memory_order_relaxed);
    RELEASE_ASSERT(count);
}

void PerformanceObserver::disassociate()
{
    ASSERT(!m_registered);
    m_performance = nullptr;
}

ExceptionOr<void> PerformanceObserver::observe(const Init& init)
{
    if (!m_performance)
        return Exception { TypeError };

    bool isBuffered = false;
    bool isTypeObserver = false;
    Vector<RefPtr<PerformanceEntry>> bufferedEntries;
    OptionSet<PerformanceEntry::Type> filter;
    if (init.entryTypes) {
        if (init.type)
            return Exception { TypeError, "either entryTypes or type must be provided"_s };
        if (m_registered && m_isTypeObserver)
            return Exception { InvalidModificationError, "observer type can't be changed once registered"_s };
        for (auto& entryType : *init.entryTypes) {
            if (auto type = PerformanceEntry::parseEntryTypeString(entryType))
                filter.add(*type);
        }
        if (filter.isEmpty())
            return {};
    } else {
        if (!init.type)
            return Exception { TypeError, "no type or entryTypes were provided"_s };
        if (m_registered && !m_isTypeObserver)
            return Exception { InvalidModificationError, "observer type can't be changed once registered"_s };
        isTypeObserver = true;
        if (auto type = PerformanceEntry::parseEntryTypeString(*init.type))
            filter.add(*type);
        else
            return {};
        if (init.buffered) {
            isBuffered = true;
            if (!bufferedEntries.tryAppend(m_entriesToDeliver.span())
                || !m_performance->tryAppendBufferedEntriesByType(*init.type, bufferedEntries)
                || !PerformanceEntry::tryStableSort(bufferedEntries))
                return Exception { OutOfMemoryError };
        }
        filter.add(m_typeFilter);
    }

    auto delivery = m_performance->prepareObserverDelivery();
    if (delivery.hasException())
        return delivery.releaseException();

    m_isTypeObserver = isTypeObserver;
    m_typeFilter = filter;
    if (isBuffered)
        m_entriesToDeliver = WTF::move(bufferedEntries);
    if (!m_registered) {
        m_performance->registerPerformanceObserver(*this);
    }
    if (isBuffered)
        m_performance->scheduleTaskIfNeeded();

    return {};
}

Vector<RefPtr<PerformanceEntry>> PerformanceObserver::takeRecords()
{
    return std::exchange(m_entriesToDeliver, {});
}

void PerformanceObserver::disconnect()
{
    Ref protectedThis { *this };
    if (m_performance)
        m_performance->unregisterPerformanceObserver(*this);

    m_entriesToDeliver.clear();
    m_typeFilter = {};
}

bool PerformanceObserver::prepareEntry()
{
    return m_entriesToDeliver.tryReserveCapacity(m_entriesToDeliver.size() + 1);
}

void PerformanceObserver::appendPreparedEntry(PerformanceEntry& entry)
{
    ASSERT(m_entriesToDeliver.size() < m_entriesToDeliver.capacity());
    m_entriesToDeliver.append(&entry);
}

Bun::Bindgen::NativeAllocationResult<void> PerformanceObserver::deliver()
{
    Ref protectedThis { *this };
    if (!m_performance || m_entriesToDeliver.isEmpty())
        return {};

    auto* context = m_performance->scriptExecutionContext();
    if (!context || context->activeDOMObjectsAreSuspended() || context->activeDOMObjectsAreStopped())
        return {};
    auto* callback = m_callback.get();
    if (!callback)
        return {};

    if (!PerformanceEntry::tryStableSort(m_entriesToDeliver))
        return Bun::Bindgen::nativeAllocationFailure();
    Vector<RefPtr<PerformanceEntry>> entries = std::exchange(m_entriesToDeliver, {});
    invokeCallback(*callback, entries.span());
    return {};
}

} // namespace WebCore
