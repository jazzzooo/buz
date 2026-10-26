/*
 * Copyright (C) 2014 Apple Inc. All rights reserved.
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

#include "SourceID.h"
#include <wtf/GenericHashKey.h>
#include <wtf/HashMap.h>
#include <wtf/Hasher.h>
#include <wtf/Vector.h>

namespace JSC {

class FunctionHasExecutedCache {
public:
    enum class RangeKind { Function, Program };
    enum class IncludeProgramRanges { No, Yes };

    struct FunctionRange {
        friend bool operator==(const FunctionRange&, const FunctionRange&) = default;
        unsigned hash() const
        {
            return computeHash(m_start, m_end, static_cast<unsigned>(m_kind));
        }

        unsigned m_start;
        unsigned m_end;
        RangeKind m_kind;
    };

    bool hasExecutedAtOffset(SourceID, unsigned offset);
    void insertUnexecutedRange(SourceID, unsigned start, unsigned end, RangeKind = RangeKind::Function);
    void removeUnexecutedRange(SourceID, unsigned start, unsigned end, RangeKind = RangeKind::Function);
    Vector<std::tuple<bool, unsigned, unsigned>> getFunctionRanges(SourceID, IncludeProgramRanges = IncludeProgramRanges::Yes);

private:
    using RangeMap = UncheckedKeyHashMap<GenericHashKey<FunctionRange>, bool>;
    using SourceIDToRangeMap = UncheckedKeyHashMap<GenericHashKey<intptr_t>, RangeMap>;
    SourceIDToRangeMap m_rangeMap;
};

} // namespace JSC
