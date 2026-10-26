/*
 * Copyright (C) 2016 Canon Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted, provided that the following conditions
 * are required to be met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Canon Inc. nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY CANON INC. AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL CANON INC. AND ITS CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "ExceptionOr.h"
#include "HTTPHeaderMap.h"
#include <variant>
#include <wtf/HashTraits.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

namespace WebCore {

class ScriptExecutionContext;

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(FetchHeaders);

class FetchHeaders : public RefCounted<FetchHeaders> {
    WTF_MAKE_NONCOPYABLE(FetchHeaders);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(FetchHeaders, FetchHeaders);

public:
    enum class Guard {
        None,
        Immutable,
        Request,
        RequestNoCors,
        Response
    };

    using Init = std::variant<Vector<Vector<String>>, Vector<KeyValuePair<String, String>>>;
    static ExceptionOr<Ref<FetchHeaders>> create(std::optional<Init>&&);

    static RefPtr<FetchHeaders> tryCreate(Guard guard = Guard::None, HTTPHeaderMap&& headers = {});
    static RefPtr<FetchHeaders> tryCreate(const FetchHeaders&);
    static ExceptionOr<String> lowercaseName(const String&);

    ExceptionOr<void> append(const String& name, const String& value);
    ExceptionOr<void> remove(const StringView);
    ExceptionOr<String> get(const StringView) const;
    ExceptionOr<String> get(HTTPHeaderName) const;
    ExceptionOr<bool> has(const StringView) const;
    ExceptionOr<void> set(const String& name, const String& value);
    ExceptionOr<void> set(const HTTPHeaderName name, const String& value);

    size_t memoryCost() const;

    inline size_t size() const
    {
        return m_headers.size();
    }

    inline size_t sizeAfterJoiningSetCookieHeader() const
    {
        return static_cast<size_t>(m_headers.commonHeaders().size()) + m_headers.uncommonHeaders().size() + !m_headers.getSetCookieHeaders().isEmpty();
    }

    bool fastHas(HTTPHeaderName name) const { return m_headers.contains(name); }
    bool fastRemove(HTTPHeaderName name)
    {
        ++m_updateCounter;
        return m_headers.remove(name);
    }

    const Vector<String, 0>& getSetCookieHeaders() const { return m_headers.getSetCookieHeaders(); }
    ExceptionOr<Vector<String>> copySetCookieHeaders() const;

    class Iterator {
        WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Iterator);

    public:
        Iterator(FetchHeaders&, bool lowerCaseKeys);
        ExceptionOr<std::optional<KeyValuePair<String, String>>> next();

    private:
        Ref<FetchHeaders> m_headers;
        // The position in the flattened entry list survives header mutations.
        size_t m_currentIndex { 0 };
        size_t m_keyIndex { 0 };
        Vector<String> m_keys;
        uint64_t m_updateCounter { 0 };
        size_t m_cookieIndex { 0 };
        bool m_lowerCaseKeys { true };
    };
    Iterator createIterator(bool lowerCaseKeys = true)
    {
        return Iterator(*this, lowerCaseKeys);
    }

    Iterator createIterator(const ScriptExecutionContext* context)
    {
        return Iterator(*this, true);
    }

    const HTTPHeaderMap& internalHeaders() const { return m_headers; }

    void setGuard(Guard);
    Guard guard() const { return m_guard; }

    uint64_t m_updateCounter { 0 };

private:
    FetchHeaders(Guard, HTTPHeaderMap&&);

    Guard m_guard;
    // Names and values use 8-bit storage so socket writers only borrow bytes.
    HTTPHeaderMap m_headers;
};

inline FetchHeaders::FetchHeaders(Guard guard, HTTPHeaderMap&& headers)
    : m_guard(guard)
    , m_headers(WTF::move(headers))
{
}

inline void FetchHeaders::setGuard(Guard guard)
{
    ASSERT(!m_headers.size());
    m_guard = guard;
}

} // namespace WebCore

namespace WTF {

template<> struct EnumTraits<WebCore::FetchHeaders::Guard> {
    using values = EnumValues<
        WebCore::FetchHeaders::Guard,
        WebCore::FetchHeaders::Guard::None,
        WebCore::FetchHeaders::Guard::Immutable,
        WebCore::FetchHeaders::Guard::Request,
        WebCore::FetchHeaders::Guard::RequestNoCors,
        WebCore::FetchHeaders::Guard::Response>;
};

}
