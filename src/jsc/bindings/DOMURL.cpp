/*
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 *           (C) 1999 Antti Koivisto (koivisto@kde.org)
 *           (C) 2000 Simon Hausmann <hausmann@kde.org>
 * Copyright (C) 2003, 2006, 2007, 2008, 2009, 2010, 2014 Apple Inc. All rights reserved.
 *           (C) 2006 Graham Dennis (graham.dennis@gmail.com)
 * Copyright (C) 2011 Google Inc. All rights reserved.
 * Copyright (C) 2012 Motorola Mobility Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "DOMURL.h"

#include "URLSearchParams.h"
#include "FormURLEncoding.h"
#include <array>
#include <new>
#include <wtf/text/MakeString.h>

namespace WebCore {

static std::array<StringView, 3> redactedURLParts(const String& input)
{
    if (input.contains('@'))
        return { "<redacted>"_s, ""_s, ""_s };

    return { "\""_s, input, "\""_s };
}

static Exception invalidURLError(const String& input, const String* base = nullptr)
{
    const auto url = redactedURLParts(input);
    String message;
    if (base) {
        const auto baseURL = redactedURLParts(*base);
        message = tryMakeString(url[0], url[1], url[2], " cannot be parsed as a URL against "_s, baseURL[0], baseURL[1], baseURL[2]);
    } else {
        message = tryMakeString(url[0], url[1], url[2], " cannot be parsed as a URL."_s);
    }
    if (message.isNull())
        return Exception { OutOfMemoryError };
    return Exception { InvalidURLError, WTF::move(message) };
}

DOMURL::DOMURL(URL&& url)
    : m_url(WTF::move(url))
{
    ASSERT(m_url.isValid());
}

ExceptionOr<Ref<DOMURL>> DOMURL::createResolved(URL&& url)
{
    void* storage;
    if (!WTF::tryFastMalloc(sizeof(DOMURL)).getValue(storage))
        return Exception { OutOfMemoryError };
    auto* object = new (NotNull, storage) DOMURL(WTF::move(url));
    return adoptRef(*object);
}

ExceptionOr<Ref<DOMURL>> DOMURL::create(const String& url)
{
    return create(url, URL { });
}

ExceptionOr<Ref<DOMURL>> DOMURL::create(const String& url, const URL& base)
{
    ASSERT(base.isValid() || base.isNull());
    WTF::URL completeURL { base, url };
    if (!completeURL.isValid())
        return invalidURLError(url);
    return createResolved(WTF::move(completeURL));
}

ExceptionOr<Ref<DOMURL>> DOMURL::create(const String& url, const String& base)
{
    if (base.isNull())
        return create(url);
    WTF::URL baseURL { base };
    if (!baseURL.isValid())
        return invalidURLError(url, &base);
    return create(url, baseURL);
}

DOMURL::~DOMURL() = default;

ExceptionOr<Ref<DOMURL>> DOMURL::createFromFileSystemPath(StringView path)
{
    auto url = URL::fileURLWithFileSystemPath(path);
    if (!url.isValid())
        return invalidURLError(url.string());
    return createResolved(WTF::move(url));
}

static URL parseInternal(const String& url, const String& base)
{
    if (base.isNull())
        return URL(url);
    URL baseURL(base);
    if (!baseURL.isValid())
        return { };
    return URL(baseURL, url);
}

ExceptionOr<RefPtr<DOMURL>> DOMURL::parse(const String& url, const String& base)
{
    auto completeURL = parseInternal(url, base);
    if (!completeURL.isValid())
        return RefPtr<DOMURL> {};
    auto result = createResolved(WTF::move(completeURL));
    if (result.hasException())
        return result.releaseException();
    return RefPtr<DOMURL> { result.releaseReturnValue() };
}

ExceptionOr<bool> DOMURL::canParse(const String& url, const String& base)
{
    auto result = parseInternal(url, base);
    return result.isValid();
}

ExceptionOr<void> DOMURL::setHref(const String& url)
{
    WTF::URL completeURL { url };
    if (!completeURL.isValid())
        return invalidURLError(url);
    return commitURL(WTF::move(completeURL));
}

ExceptionOr<void> DOMURL::setFullURL(const URL& url)
{
    if (!url.isValid())
        return { };
    return commitURL(URL(url));
}

ExceptionOr<void> DOMURL::commitURL(URL&& url)
{
    RELEASE_ASSERT(url.isValid());
    if (m_searchParams && (m_searchParams->m_queryDirty || url.query() != m_url.query())) {
        auto pairs = FormURLEncoding::parse(url.query());
        if (pairs.hasException())
            return pairs.releaseException();
        m_searchParams->m_pairs = pairs.releaseReturnValue();
        m_searchParams->m_queryDirty = false;
    }
    m_url = WTF::move(url);
    return {};
}

ExceptionOr<URL> DOMURL::href() const
{
    if (!m_searchParams || !m_searchParams->m_queryDirty)
        return URL(m_url);
    auto serialized = m_searchParams->toString();
    if (serialized.hasException())
        return serialized.releaseException();
    const auto query = serialized.releaseReturnValue();
    m_url.setQuery(query.isEmpty() ? StringView { } : StringView(query));
    m_searchParams->m_queryDirty = false;
    return URL(m_url);
}

ExceptionOr<Ref<URLSearchParams>> DOMURL::searchParams()
{
    if (!m_searchParams) {
        auto created = URLSearchParams::createFromQuery(m_url.query());
        if (created.hasException())
            return created.releaseException();
        m_searchParams = created.releaseReturnValue();
    }
    return Ref { *m_searchParams };
}

} // namespace WebCore
