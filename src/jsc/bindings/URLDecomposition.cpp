/*
 * Copyright (C) 2014-2020 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "URLDecomposition.h"

#include <array>
#include <wtf/URLParser.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

using WTF::URLParser;

static ExceptionOr<String> checkedComponent(String&& value)
{
    if (value.isNull())
        return Exception { OutOfMemoryError };
    return WTF::move(value);
}

struct PortDigits {
    explicit PortDigits(uint16_t port)
    {
        do {
            characters[--start] = static_cast<Latin1Character>('0' + port % 10);
            port /= 10;
        } while (port);
    }

    StringView view() const { return std::span<const Latin1Character>(characters).subspan(start); }

    std::array<Latin1Character, 5> characters;
    size_t start { characters.size() };
};

static ExceptionOr<String> serializeHost(const URL& url, bool includeProtocol)
{
    const auto port = url.port();
    const PortDigits digits(port.value_or(0));
    return checkedComponent(tryMakeString(
        includeProtocol ? url.protocol() : StringView(""_s),
        includeProtocol ? "://"_s : ""_s,
        url.host(),
        port ? ":"_s : ""_s,
        port ? digits.view() : StringView(""_s)));
}

ExceptionOr<String> URLDecomposition::origin() const
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    return origin(result.releaseReturnValue());
}

ExceptionOr<String> URLDecomposition::origin(const URL& fullURL)
{
    if (fullURL.protocolIsInHTTPFamily() or fullURL.protocolIsInFTPFamily() or fullURL.protocolIs("ws"_s) or fullURL.protocolIs("wss"_s))
        return serializeHost(fullURL, true);
    if (fullURL.protocolIsBlob()) {
        const String path = tryMakeString(fullURL.path());
        if (path.isNull())
            return Exception { OutOfMemoryError };
        WTF::URL parsed { path };
        if (parsed.isValid()) {
            const auto& subUrl = parsed;
            if (subUrl.protocolIsInHTTPFamily() or subUrl.protocolIsInFTPFamily() or subUrl.protocolIs("ws"_s) or subUrl.protocolIs("wss"_s) or subUrl.protocolIsFile())
                return serializeHost(subUrl, true);
        }
    }
    return String("null"_s);
}

ExceptionOr<String> URLDecomposition::protocol() const
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    return checkedComponent(tryMakeString(fullURL.protocol(), ':'));
}

ExceptionOr<void> URLDecomposition::setProtocol(StringView value)
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    URL copy = result.releaseReturnValue();
    copy.setProtocol(value);
    return setFullURL(copy);
}

ExceptionOr<String> URLDecomposition::username() const
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    return checkedComponent(tryMakeString(result.releaseReturnValue().encodedUser()));
}

ExceptionOr<void> URLDecomposition::setUsername(StringView user)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (fullURL.host().isEmpty() || fullURL.protocolIsFile())
        return {};
    fullURL.setUser(user);
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::password() const
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    return checkedComponent(tryMakeString(result.releaseReturnValue().encodedPassword()));
}

ExceptionOr<void> URLDecomposition::setPassword(StringView password)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (fullURL.host().isEmpty() || fullURL.protocolIsFile())
        return {};
    fullURL.setPassword(password);
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::host() const
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    return serializeHost(result.releaseReturnValue(), false);
}

ExceptionOr<void> URLDecomposition::setHost(StringView value)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (fullURL.hasOpaquePath())
        return {};
    fullURL.setHostAndPort(value);
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::hostname() const
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    return checkedComponent(tryMakeString(result.releaseReturnValue().host()));
}

ExceptionOr<void> URLDecomposition::setHostname(StringView host)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (fullURL.hasOpaquePath())
        return {};
    fullURL.setHost(host);
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::port() const
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    auto port = result.releaseReturnValue().port();
    if (!port)
        return String(emptyString());
    const PortDigits digits(*port);
    return checkedComponent(tryMakeString(digits.view()));
}

// Outer optional is whether we could parse at all. Inner optional is "no port specified".
std::optional<std::optional<uint16_t>> URLDecomposition::parsePort(StringView string, StringView protocol)
{
    if (string.isEmpty())
        return std::optional<uint16_t> { std::nullopt };
    // https://url.spec.whatwg.org/#port-state with state override given.
    uint32_t port { 0 };
    bool foundDigit = false;
    for (size_t i = 0; i < string.length(); ++i) {
        auto c = string[i];
        // https://infra.spec.whatwg.org/#ascii-tab-or-newline
        if (c == 0x0009 || c == 0x000A || c == 0x000D)
            continue;
        if (isASCIIDigit(c)) {
            port = port * 10 + c - '0';
            foundDigit = true;
            if (port > std::numeric_limits<uint16_t>::max())
                return std::nullopt;
            continue;
        }
        if (!foundDigit)
            return std::nullopt;
        break;
    }
    if (!foundDigit)
        return std::nullopt;
    if (WTF::isDefaultPortForProtocol(static_cast<uint16_t>(port), protocol))
        return std::optional<uint16_t> { std::nullopt };
    return { { static_cast<uint16_t>(port) } };
}

ExceptionOr<void> URLDecomposition::setPort(StringView value)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (fullURL.host().isEmpty() || fullURL.protocolIsFile())
        return {};
    auto port = parsePort(value, fullURL.protocol());
    if (!port)
        return {};
    fullURL.setPort(*port);
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::pathname() const
{
    auto result = fullURL();
    if (result.hasException())
        return result.releaseException();
    return checkedComponent(tryMakeString(result.releaseReturnValue().path()));
}

ExceptionOr<void> URLDecomposition::setPathname(StringView value)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (fullURL.hasOpaquePath())
        return {};
    fullURL.setPath(value);
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::search() const
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    return checkedComponent(tryMakeString(fullURL.query().isEmpty() ? StringView(""_s) : fullURL.queryWithLeadingQuestionMark()));
}

ExceptionOr<void> URLDecomposition::setSearch(const String& value)
{
    auto fullURL = urlForQueryReplacement();
    fullURL.setQuery(value.isEmpty() ? StringView {} : StringView(value));
    return setFullURL(fullURL);
}

ExceptionOr<String> URLDecomposition::hash() const
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    return checkedComponent(tryMakeString(fullURL.fragmentIdentifier().isEmpty() ? StringView(""_s) : fullURL.fragmentIdentifierWithLeadingNumberSign()));
}

ExceptionOr<void> URLDecomposition::setHash(StringView value)
{
    auto result = this->fullURL();
    if (result.hasException())
        return result.releaseException();
    auto fullURL = result.releaseReturnValue();
    if (value.isEmpty())
        fullURL.removeFragmentIdentifier();
    else
        fullURL.setFragmentIdentifier(value.startsWith('#') ? value.substring(1) : value);
    return setFullURL(fullURL);
}

}
