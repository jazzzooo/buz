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

#pragma once

#include "SchemaBindingsEnumerations.h"
#include <algorithm>
#include <utility>
#include <wtf/EnumTraits.h>
#include <wtf/Forward.h>

namespace WebCore {

using HTTPHeaderName = Bun::Bindgen::HTTPHeaderName;
inline constexpr auto& httpHeaderNameEntries = Bun::Bindgen::EnumerationTraits<HTTPHeaderName>::entries;
inline constexpr size_t numHTTPHeaderNames = httpHeaderNameEntries.size();
inline constexpr size_t maxHTTPHeaderNameLength = [] {
    size_t length = 0;
    for (const auto& entry : httpHeaderNameEntries)
        length = std::max(length, entry.name.size());
    return length;
}();

static_assert([] {
    for (size_t i = 0; i < numHTTPHeaderNames; ++i) {
        if (static_cast<size_t>(httpHeaderNameEntries[i].value) != i || httpHeaderNameEntries[i].name.empty())
            return false;
        for (unsigned char character : httpHeaderNameEntries[i].name) {
            if (!character || character > 0x7f)
                return false;
        }
    }
    return true;
}());

bool findHTTPHeaderName(StringView, HTTPHeaderName&);
WEBCORE_EXPORT StringView httpHeaderNameString(HTTPHeaderName);

}

namespace WTF {

template<> struct EnumTraits<WebCore::HTTPHeaderName> {
    template<size_t... Index> static auto members(std::index_sequence<Index...>)
        -> EnumValues<WebCore::HTTPHeaderName, WebCore::httpHeaderNameEntries[Index].value...>;
    using values = decltype(members(std::make_index_sequence<WebCore::numHTTPHeaderNames> {}));
};

const String& httpHeaderNameStringImpl(WebCore::HTTPHeaderName);
const String& httpHeaderNameDefaultCaseStringImpl(WebCore::HTTPHeaderName);

}
