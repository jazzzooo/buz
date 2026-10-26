/*
 * Copyright (C) 2012 Intel Inc. All rights reserved.
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
#include "PerformanceUserTiming.h"

// #include "Document.h"
// #include "FrameDestructionObserverInlines.h"
// #include "InspectorInstrumetation.h"
#include "MessagePort.h"
#include "PerformanceMarkOptions.h"
#include "PerformanceMeasureOptions.h"
#include "SerializedScriptValue.h"
// #include "WorkerOrWorkletGlobalScope.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <wtf/SortedArrayMap.h>

namespace WebCore {

static constexpr SortedArraySet restrictedMarkNames { std::to_array<ComparableASCIILiteral>({
    "connectEnd"_s,
    "connectStart"_s,
    "domComplete"_s,
    "domContentLoadedEventEnd"_s,
    "domContentLoadedEventStart"_s,
    "domInteractive"_s,
    "domLoading"_s,
    "domainLookupEnd"_s,
    "domainLookupStart"_s,
    "fetchStart"_s,
    "loadEventEnd"_s,
    "loadEventStart"_s,
    "navigationStart"_s,
    "redirectEnd"_s,
    "redirectStart"_s,
    "requestStart"_s,
    "responseEnd"_s,
    "responseStart"_s,
    "secureConnectionStart"_s,
    "unloadEventEnd"_s,
    "unloadEventStart"_s,
}) };

bool PerformanceUserTiming::isRestrictedMarkName(const String& markName)
{
    return restrictedMarkNames.contains(markName);
}

PerformanceUserTiming::PerformanceUserTiming(Performance& performance)
    : m_performance(performance)
{
}

size_t PerformanceUserTiming::memoryCost() const
{
    return sizeof(PerformanceUserTiming) + m_marks.memoryCost() + m_measures.memoryCost();
}

bool PerformanceUserTiming::recordEntry(PerformanceEntry& entry)
{
    switch (entry.performanceEntryType()) {
    case PerformanceEntry::Type::Mark:
        return m_marks.tryAdd(entry);
    case PerformanceEntry::Type::Measure:
        return m_measures.tryAdd(entry);
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

ExceptionOr<Ref<PerformanceMark>> PerformanceUserTiming::createMark(JSC::JSGlobalObject& globalObject, const String& markName, std::optional<PerformanceMarkOptions>&& markOptions)
{
    auto& context = *m_performance.scriptExecutionContext();
    return PerformanceMark::create(globalObject, context, markName, WTF::move(markOptions));
}

void PerformanceUserTiming::clearMarks(const String& markName)
{
    m_marks.clear(markName);
}

ExceptionOr<double> PerformanceUserTiming::convertMarkToTimestamp(const std::variant<String, double>& mark) const
{
    return std::visit([&](auto& value) {
        return convertMarkToTimestamp(value);
    },
        mark);
}

ExceptionOr<double> PerformanceUserTiming::convertMarkToTimestamp(const String& mark) const
{
    if (const auto* entries = m_marks.find(mark))
        return entries->last()->startTime();

    return Exception { SyntaxError, makeString("No mark named '"_s, mark, "' exists"_s) };
}

ExceptionOr<double> PerformanceUserTiming::convertMarkToTimestamp(double mark) const
{
    if (mark < 0)
        return Exception { TypeError };
    return mark;
}

ExceptionOr<Ref<PerformanceMeasure>> PerformanceUserTiming::createMeasure(const String& measureName, const String& startMark, const String& endMark)
{
    double endTime;
    if (!endMark.isNull()) {
        auto end = convertMarkToTimestamp(endMark);
        if (end.hasException())
            return end.releaseException();
        endTime = end.returnValue();
    } else
        endTime = m_performance.now();

    double startTime;
    if (!startMark.isNull()) {
        auto start = convertMarkToTimestamp(startMark);
        if (start.hasException())
            return start.releaseException();
        startTime = start.returnValue();
    } else
        startTime = 0.0;

    auto measure = PerformanceMeasure::create(measureName, startTime, endTime, nullptr);
    if (measure.hasException())
        return measure.releaseException();

    return measure.releaseReturnValue();
}

ExceptionOr<Ref<PerformanceMeasure>> PerformanceUserTiming::createMeasure(JSC::JSGlobalObject& globalObject, const String& measureName, const PerformanceMeasureOptions& measureOptions)
{
    double endTime;
    if (measureOptions.end) {
        auto end = convertMarkToTimestamp(*measureOptions.end);
        if (end.hasException())
            return end.releaseException();
        endTime = end.returnValue();
    } else if (measureOptions.start && measureOptions.duration) {
        auto start = convertMarkToTimestamp(*measureOptions.start);
        if (start.hasException())
            return start.releaseException();
        auto duration = convertMarkToTimestamp(*measureOptions.duration);
        if (duration.hasException())
            return duration.releaseException();
        endTime = start.returnValue() + duration.returnValue();
    } else
        endTime = m_performance.now();

    double startTime;
    if (measureOptions.start) {
        auto start = convertMarkToTimestamp(*measureOptions.start);
        if (start.hasException())
            return start.releaseException();
        startTime = start.returnValue();
    } else if (measureOptions.duration && measureOptions.end) {
        auto duration = convertMarkToTimestamp(*measureOptions.duration);
        if (duration.hasException())
            return duration.releaseException();
        auto end = convertMarkToTimestamp(*measureOptions.end);
        if (end.hasException())
            return end.releaseException();
        startTime = end.returnValue() - duration.returnValue();
    } else
        startTime = 0;

    JSC::JSValue detail = measureOptions.detail;
    if (detail.isUndefined())
        detail = JSC::jsNull();

    if (!detail.isNull()) {
        Vector<RefPtr<MessagePort>> ignoredMessagePorts;
        auto serializedDetail = SerializedScriptValue::create(globalObject, detail, {}, ignoredMessagePorts);
        if (serializedDetail.hasException())
            return serializedDetail.releaseException();

        auto measure = PerformanceMeasure::create(measureName, startTime, endTime, serializedDetail.releaseReturnValue());
        if (measure.hasException())
            return measure.releaseException();

        return measure.releaseReturnValue();
    } else {
        auto measure = PerformanceMeasure::create(measureName, startTime, endTime, nullptr);
        if (measure.hasException())
            return measure.releaseException();

        return measure.releaseReturnValue();
    }
}

static bool isNonEmptyDictionary(const PerformanceMeasureOptions& measureOptions)
{
    return !measureOptions.detail.isUndefined() || measureOptions.start || measureOptions.duration || measureOptions.end;
}

ExceptionOr<Ref<PerformanceMeasure>> PerformanceUserTiming::createMeasure(JSC::JSGlobalObject& globalObject, const String& measureName, std::optional<StartOrMeasureOptions>&& startOrMeasureOptions, const String& endMark)
{
    if (startOrMeasureOptions) {
        return std::visit(
            WTF::makeVisitor(
                [&](const PerformanceMeasureOptions& measureOptions) -> ExceptionOr<Ref<PerformanceMeasure>> {
                    if (isNonEmptyDictionary(measureOptions)) {
                        if (!endMark.isNull())
                            return Exception { TypeError };
                        if (!measureOptions.start && !measureOptions.end)
                            return Exception { TypeError };
                        if (measureOptions.start && measureOptions.duration && measureOptions.end)
                            return Exception { TypeError };
                    }

                    return createMeasure(globalObject, measureName, measureOptions);
                },
                [&](const String& startMark) -> ExceptionOr<Ref<PerformanceMeasure>> {
                    return createMeasure(measureName, startMark, endMark);
                }),
            *startOrMeasureOptions);
    }

    return createMeasure(measureName, {}, endMark);
}

void PerformanceUserTiming::clearMeasures(const String& measureName)
{
    m_measures.clear(measureName);
}

bool PerformanceUserTiming::tryAppendMarks(Vector<RefPtr<PerformanceEntry>>& entries, const String& name) const
{
    return m_marks.tryAppendTo(entries, name);
}

bool PerformanceUserTiming::tryAppendMeasures(Vector<RefPtr<PerformanceEntry>>& entries, const String& name) const
{
    return m_measures.tryAppendTo(entries, name);
}

} // namespace WebCore
