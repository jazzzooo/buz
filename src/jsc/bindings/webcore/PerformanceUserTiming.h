/*
 * Copyright (C) 2012 Intel Inc. All rights reserved.
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

#include "ExceptionOr.h"
#include "PerformanceMark.h"
#include "PerformanceMeasure.h"
#include "PerformanceEntryHistory.h"
#include <memory>
#include <wtf/FastMalloc.h>

namespace JSC {
class JSGlobalObject;
}

namespace WebCore {

class Performance;

class PerformanceUserTiming {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(PerformanceUserTiming);

public:
    static std::unique_ptr<PerformanceUserTiming> tryCreate(Performance& performance)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(PerformanceUserTiming)).getValue(allocation))
            return nullptr;
        return std::unique_ptr<PerformanceUserTiming> { new (NotNull, allocation) PerformanceUserTiming(performance) };
    }

    explicit PerformanceUserTiming(Performance&);

    ExceptionOr<Ref<PerformanceMark>> createMark(JSC::JSGlobalObject&, const String& markName, std::optional<PerformanceMarkOptions>&&);
    void clearMarks(const String& markName);

    using StartOrMeasureOptions = std::variant<String, PerformanceMeasureOptions>;
    ExceptionOr<Ref<PerformanceMeasure>> createMeasure(JSC::JSGlobalObject&, const String& measureName, std::optional<StartOrMeasureOptions>&&, const String& endMark);
    bool recordEntry(PerformanceEntry&);
    void clearMeasures(const String& measureName);

    bool tryAppendMarks(Vector<RefPtr<PerformanceEntry>>&, const String& name = String {}) const;
    bool tryAppendMeasures(Vector<RefPtr<PerformanceEntry>>&, const String& name = String {}) const;

    static bool isRestrictedMarkName(const String& markName);

    size_t memoryCost() const;

private:
    ExceptionOr<double> convertMarkToTimestamp(const std::variant<String, double>&) const;
    ExceptionOr<double> convertMarkToTimestamp(const String& markName) const;
    ExceptionOr<double> convertMarkToTimestamp(double) const;

    ExceptionOr<Ref<PerformanceMeasure>> createMeasure(const String& measureName, const String& startMark, const String& endMark);
    ExceptionOr<Ref<PerformanceMeasure>> createMeasure(JSC::JSGlobalObject&, const String& measureName, const PerformanceMeasureOptions&);

    Performance& m_performance;
    PerformanceEntryHistory m_marks;
    PerformanceEntryHistory m_measures;
};

}
