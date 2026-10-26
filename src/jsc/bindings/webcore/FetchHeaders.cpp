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

#include "config.h"
#include "FetchHeaders.h"
#include "HTTPHeaderNames.h"

#include "HTTPParsers.h"
#include <wtf/ASCIICType.h>
#include <wtf/text/MakeString.h>
#include "wtf/DebugHeap.h"

namespace WebCore {

DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(FetchHeaders);

RefPtr<FetchHeaders> FetchHeaders::tryCreate(Guard guard, HTTPHeaderMap&& headers)
{
    auto* memory = FetchHeadersMalloc::tryMalloc(sizeof(FetchHeaders));
    if (!memory)
        return nullptr;
    return adoptRef(*new (memory) FetchHeaders(guard, WTF::move(headers)));
}

RefPtr<FetchHeaders> FetchHeaders::tryCreate(const FetchHeaders& source)
{
    HTTPHeaderMap headers;
    if (!headers.commonHeaders().tryAppend(source.m_headers.commonHeaders().span())
        || !headers.uncommonHeaders().tryAppend(source.m_headers.uncommonHeaders().span())
        || !headers.getSetCookieHeaders().tryAppend(source.m_headers.getSetCookieHeaders().span()))
        return nullptr;
    return tryCreate(Guard::None, WTF::move(headers));
}

// https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
static void removePrivilegedNoCORSRequestHeaders(HTTPHeaderMap& headers)
{
    headers.remove(HTTPHeaderName::Range);
}

template<typename... Parts> static Exception headerTypeError(const Parts&... parts)
{
    auto message = tryMakeString(parts...);
    if (message.isNull())
        return Exception { OutOfMemoryError };
    return Exception { TypeError, WTF::move(message) };
}

static ExceptionOr<String> copyHeaderBytes(StringView value)
{
    std::span<Latin1Character> bytes;
    auto impl = StringImpl::tryCreateUninitialized(value.length(), bytes);
    if (!impl)
        return Exception { OutOfMemoryError };
    for (size_t i = 0; i < value.length(); ++i) {
        RELEASE_ASSERT(value[i] <= 0xff);
        bytes[i] = static_cast<Latin1Character>(value[i]);
    }
    return String(WTF::move(impl));
}

static ExceptionOr<String> normalizeHeader(StringView name, const String& value)
{
    if (!isValidHTTPToken(name))
        return headerTypeError("Invalid header name: '"_s, name, "'"_s);
    if (!value.containsOnlyLatin1())
        return headerTypeError("Header '"_s, name, "' has invalid value: '"_s, value, "'"_s);
    auto trimmed = StringView(value).trim(isHTTPSpace);
    if (value.is8Bit() && trimmed.length() == value.length())
        return String(value);
    return copyHeaderBytes(trimmed);
}

static ExceptionOr<void> validateHeaderValue(StringView name, const String& value, FetchHeaders::Guard guard)
{
    ASSERT(value.isEmpty() || (!isHTTPSpace(value[0]) && !isHTTPSpace(value[value.length() - 1])));
    if (!isValidHTTPHeaderValue(value))
        return headerTypeError("Header '"_s, name, "' has invalid value: '"_s, value, "'"_s);
    if (guard == FetchHeaders::Guard::Immutable)
        return Exception { TypeError, "Headers object's guard is 'immutable'"_s };
    return {};
}

static ExceptionOr<void> appendToHeaderMap(const String& name, const String& value, HTTPHeaderMap& headers, FetchHeaders::Guard guard)
{
    auto normalized = normalizeHeader(name, value);
    if (normalized.hasException())
        return normalized.releaseException();
    auto normalizedValue = normalized.releaseReturnValue();
    HTTPHeaderName commonName;
    const bool isCommon = findHTTPHeaderName(name, commonName);
    auto validation = validateHeaderValue(isCommon ? StringView(WTF::httpHeaderNameDefaultCaseStringImpl(commonName)) : StringView(name), normalizedValue, guard);
    if (validation.hasException())
        return validation.releaseException();
    if (isCommon) {
        if (!headers.tryAdd(commonName, normalizedValue))
            return Exception { OutOfMemoryError };
    } else {
        auto normalizedName = name.is8Bit() ? ExceptionOr<String>(String(name)) : copyHeaderBytes(name);
        if (normalizedName.hasException())
            return normalizedName.releaseException();
        if (!headers.tryAdd(normalizedName.releaseReturnValue(), normalizedValue))
            return Exception { OutOfMemoryError };
    }
    return {};
}

// https://fetch.spec.whatwg.org/#concept-headers-fill
static ExceptionOr<void> fillHeaderMap(HTTPHeaderMap& headers, const FetchHeaders::Init& headersInit, FetchHeaders::Guard guard)
{
    if (std::holds_alternative<Vector<Vector<String>>>(headersInit)) {
        auto& sequence = std::get<Vector<Vector<String>>>(headersInit);
        for (auto& header : sequence) {
            if (header.size() != 2)
                return Exception { TypeError, "Header sub-sequence must contain exactly two items"_s };
            auto result = appendToHeaderMap(header[0], header[1], headers, guard);
            if (result.hasException())
                return result.releaseException();
        }
    } else {
        auto& record = std::get<Vector<KeyValuePair<String, String>>>(headersInit);
        for (auto& header : record) {
            auto result = appendToHeaderMap(header.key, header.value, headers, guard);
            if (result.hasException())
                return result.releaseException();
        }
    }

    return {};
}

ExceptionOr<Ref<FetchHeaders>> FetchHeaders::create(std::optional<Init>&& headersInit)
{
    HTTPHeaderMap headers;

    if (headersInit) {
        auto result = fillHeaderMap(headers, *headersInit, Guard::None);
        if (result.hasException())
            return result.releaseException();
    }

    auto result = tryCreate(Guard::None, WTF::move(headers));
    if (!result)
        return Exception { OutOfMemoryError };
    return result.releaseNonNull();
}

ExceptionOr<void> FetchHeaders::append(const String& name, const String& value)
{
    auto result = appendToHeaderMap(name, value, m_headers, m_guard);
    if (result.hasException())
        return result.releaseException();
    ++m_updateCounter;
    return {};
}

// https://fetch.spec.whatwg.org/#dom-headers-delete
ExceptionOr<void> FetchHeaders::remove(const StringView name)
{
    ASSERT_WITH_MESSAGE(m_guard == FetchHeaders::Guard::None, "We don't use guards in Bun");

    HTTPHeaderName headerName;
    if (findHTTPHeaderName(name, headerName)) {
        ++m_updateCounter;
        m_headers.remove(headerName);
        return {};
    }

    if (!isValidHTTPToken(name))
        return headerTypeError("Invalid header name: '"_s, name, "'"_s);

    ++m_updateCounter;
    m_headers.removeUncommonHeader(name);

    return {};
}

size_t FetchHeaders::memoryCost() const
{
    return m_headers.memoryCost() + sizeof(*this);
}

ExceptionOr<String> FetchHeaders::get(const StringView name) const
{
    HTTPHeaderName commonName;
    if (findHTTPHeaderName(name, commonName))
        return get(commonName);
    if (!isValidHTTPToken(name))
        return headerTypeError("Invalid header name: '"_s, name, "'"_s);
    return m_headers.get(name);
}

ExceptionOr<String> FetchHeaders::get(HTTPHeaderName name) const
{
    const auto& cookies = getSetCookieHeaders();
    if (cookies.size() > 1 && name == HTTPHeaderName::SetCookie) {
        size_t length = 0;
        for (size_t i = 0; i < cookies.size(); ++i) {
            const size_t partLength = static_cast<size_t>(cookies[i].length()) + (i ? 2 : 0);
            if (partLength > StringImpl::MaxLength - length)
                return Exception { OutOfMemoryError };
            length += partLength;
        }
        std::span<Latin1Character> destination;
        auto impl = StringImpl::tryCreateUninitialized(length, destination);
        if (!impl)
            return Exception { OutOfMemoryError };
        for (size_t i = 0; i < cookies.size(); ++i) {
            if (i) {
                destination[0] = ',';
                destination[1] = ' ';
                destination = destination.subspan(2);
            }
            RELEASE_ASSERT(cookies[i].is8Bit());
            const auto bytes = cookies[i].span8();
            if (!bytes.empty())
                memcpy(destination.data(), bytes.data(), bytes.size());
            destination = destination.subspan(bytes.size());
        }
        RELEASE_ASSERT(destination.empty());
        return String(WTF::move(impl));
    }
    return m_headers.get(name);
}

ExceptionOr<bool> FetchHeaders::has(const StringView name) const
{
    bool has = m_headers.contains(name);
    if (!has) {
        if (!isValidHTTPToken(name))
            return headerTypeError("Invalid header name: '"_s, name, '"');
    }
    return has;
}

ExceptionOr<void> FetchHeaders::set(const HTTPHeaderName name, const String& value)
{
    return set(WTF::httpHeaderNameDefaultCaseStringImpl(name), value);
}

ExceptionOr<void> FetchHeaders::set(const String& name, const String& value)
{
    auto normalized = normalizeHeader(name, value);
    if (normalized.hasException())
        return normalized.releaseException();
    auto normalizedValue = normalized.releaseReturnValue();
    auto validation = validateHeaderValue(name, normalizedValue, m_guard);
    if (validation.hasException())
        return validation.releaseException();
    auto normalizedName = name.is8Bit() ? ExceptionOr<String>(String(name)) : copyHeaderBytes(name);
    if (normalizedName.hasException())
        return normalizedName.releaseException();
    if (!m_headers.trySet(normalizedName.releaseReturnValue(), normalizedValue))
        return Exception { OutOfMemoryError };

    ++m_updateCounter;

    if (m_guard == FetchHeaders::Guard::RequestNoCors)
        removePrivilegedNoCORSRequestHeaders(m_headers);

    return {};
}

ExceptionOr<String> FetchHeaders::lowercaseName(const String& name)
{
    RELEASE_ASSERT(name.is8Bit());
    bool needsCopy = false;
    for (size_t i = 0; i < name.length(); ++i) {
        if (isASCIIUpper(name[i])) {
            needsCopy = true;
            break;
        }
    }
    if (!needsCopy)
        return String(name);

    std::span<Latin1Character> destination;
    auto impl = StringImpl::tryCreateUninitialized(name.length(), destination);
    if (!impl)
        return Exception { OutOfMemoryError };
    const auto source = name.span8();
    for (size_t i = 0; i < source.size(); ++i)
        destination[i] = toASCIILower(source[i]);
    return String(WTF::move(impl));
}

ExceptionOr<Vector<String>> FetchHeaders::copySetCookieHeaders() const
{
    const auto& cookies = getSetCookieHeaders();
    Vector<String> result;
    if (!result.tryReserveInitialCapacity(cookies.size()))
        return Exception { OutOfMemoryError };
    for (const auto& cookie : cookies)
        result.unsafeAppendWithoutCapacityCheck(cookie);
    return result;
}

ExceptionOr<std::optional<KeyValuePair<String, String>>> FetchHeaders::Iterator::next()
{
    if (m_keys.isEmpty() || m_updateCounter != m_headers->m_updateCounter) {
        const auto& headers = m_headers->m_headers;
        const bool hasSetCookie = !headers.getSetCookieHeaders().isEmpty();
        const size_t keyCount = static_cast<size_t>(headers.commonHeaders().size()) + headers.uncommonHeaders().size() + hasSetCookie;
        Vector<String> keys;
        if (!keys.tryReserveInitialCapacity(keyCount))
            return Exception { OutOfMemoryError };
        for (const auto& header : headers.commonHeaders()) {
            keys.unsafeAppendWithoutCapacityCheck(m_lowerCaseKeys
                    ? WTF::httpHeaderNameStringImpl(header.key)
                    : WTF::httpHeaderNameDefaultCaseStringImpl(header.key));
        }
        for (const auto& header : headers.uncommonHeaders()) {
            if (m_lowerCaseKeys) {
                auto key = lowercaseName(header.key);
                if (key.hasException())
                    return key.releaseException();
                keys.unsafeAppendWithoutCapacityCheck(key.releaseReturnValue());
            } else
                keys.unsafeAppendWithoutCapacityCheck(header.key);
        }
        std::sort(keys.begin(), keys.end(), WTF::codePointCompareLessThan);
        if (hasSetCookie)
            keys.unsafeAppendWithoutCapacityCheck(WTF::httpHeaderNameStringImpl(HTTPHeaderName::SetCookie));

        m_keys = WTF::move(keys);
        m_keyIndex = 0;
        m_cookieIndex = 0;
        size_t remaining = m_currentIndex;
        while (m_keyIndex < m_keys.size()) {
            const bool isSetCookie = m_keys[m_keyIndex] == "set-cookie"_s;
            const size_t entryCount = isSetCookie ? headers.getSetCookieHeaders().size() : 1;
            if (remaining < entryCount) {
                if (isSetCookie)
                    m_cookieIndex = remaining;
                break;
            }
            remaining -= entryCount;
            ++m_keyIndex;
        }

        m_updateCounter = m_headers->m_updateCounter;
    }

    auto& setCookieHeaders = m_headers->m_headers.getSetCookieHeaders();

    while (m_keyIndex < m_keys.size()) {
        auto key = m_keys[m_keyIndex];

        if (key == "set-cookie"_s) {
            if (m_cookieIndex < setCookieHeaders.size()) {
                String value = setCookieHeaders[m_cookieIndex++];
                ++m_currentIndex;
                return std::optional { KeyValuePair<String, String> { WTF::httpHeaderNameStringImpl(HTTPHeaderName::SetCookie), WTF::move(value) } };
            }
            ++m_keyIndex;
            continue;
        }

        ++m_keyIndex;
        auto value = m_headers->m_headers.get(key);
        if (!value.isNull()) {
            ++m_currentIndex;
            return std::optional { KeyValuePair<String, String> { WTF::move(key), WTF::move(value) } };
        }
    }

    return { std::nullopt };
}

FetchHeaders::Iterator::Iterator(FetchHeaders& headers, bool lowerCaseKeys)
    : m_headers(headers)
    , m_lowerCaseKeys(lowerCaseKeys)
{
}

} // namespace WebCore
