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
#include "HTTPHeaderNames.h"

#include <bit>
#include <wtf/ASCIICType.h>
#include <wtf/text/StringView.h>

namespace WebCore {

static constexpr uint32_t headerNameHash(std::string_view name)
{
    uint32_t hash = 2166136261u;
    for (unsigned char character : name) {
        const auto lowercase = isASCIIUpper(character) ? character + ('a' - 'A') : character;
        hash = (hash ^ lowercase) * 16777619u;
    }
    return hash;
}

static constexpr auto headerNameTable = [] {
    constexpr auto capacity = std::bit_ceil(numHTTPHeaderNames * 2);
    std::array<size_t, capacity> table;
    table.fill(numHTTPHeaderNames);
    for (size_t i = 0; i < numHTTPHeaderNames; ++i) {
        auto slot = headerNameHash(httpHeaderNameEntries[i].name) & (capacity - 1);
        while (table[slot] != numHTTPHeaderNames)
            slot = (slot + 1) & (capacity - 1);
        table[slot] = i;
    }
    return table;
}();

bool findHTTPHeaderName(StringView name, HTTPHeaderName& result)
{
    if (name.isEmpty() || name.length() > maxHTTPHeaderNameLength)
        return false;
    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < name.length(); ++i) {
        const auto character = name[i];
        if (!isASCII(character))
            return false;
        hash = (hash ^ toASCIILower(character)) * 16777619u;
    }
    auto slot = hash & (headerNameTable.size() - 1);
    for (;;) {
        const auto index = headerNameTable[slot];
        if (index == numHTTPHeaderNames)
            return false;
        const auto& entry = httpHeaderNameEntries[index];
        if (equalIgnoringASCIICase(name, StringView(std::span(entry.name)))) {
            result = entry.value;
            return true;
        }
        slot = (slot + 1) & (headerNameTable.size() - 1);
    }
}

StringView httpHeaderNameString(HTTPHeaderName name)
{
    const auto index = static_cast<size_t>(name);
    RELEASE_ASSERT(index < numHTTPHeaderNames);
    return StringView(std::span(httpHeaderNameEntries[index].name));
}

}
