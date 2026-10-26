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

#pragma once

#include "root.h"
#include "ExceptionOr.h"

#include <wtf/URL.h>

#include <wtf/Forward.h>

namespace WebCore {

class URLDecomposition {
public:
    // Parse a port string with optional protocol for default port detection
    // Returns nullopt on parse error, or optional<uint16_t> (nullopt means empty/default port)
    static std::optional<std::optional<uint16_t>> parsePort(StringView port, StringView protocol);

    ExceptionOr<String> origin() const;
    static ExceptionOr<String> origin(const URL&);

    WEBCORE_EXPORT ExceptionOr<String> protocol() const;
    ExceptionOr<void> setProtocol(StringView);

    ExceptionOr<String> username() const;
    ExceptionOr<void> setUsername(StringView);

    ExceptionOr<String> password() const;
    ExceptionOr<void> setPassword(StringView);

    WEBCORE_EXPORT ExceptionOr<String> host() const;
    ExceptionOr<void> setHost(StringView);

    WEBCORE_EXPORT ExceptionOr<String> hostname() const;
    ExceptionOr<void> setHostname(StringView);

    WEBCORE_EXPORT ExceptionOr<String> port() const;
    ExceptionOr<void> setPort(StringView);

    WEBCORE_EXPORT ExceptionOr<String> pathname() const;
    ExceptionOr<void> setPathname(StringView);

    WEBCORE_EXPORT ExceptionOr<String> search() const;
    ExceptionOr<void> setSearch(const String&);

    WEBCORE_EXPORT ExceptionOr<String> hash() const;
    ExceptionOr<void> setHash(StringView);

protected:
    virtual ~URLDecomposition() = default;

private:
    virtual ExceptionOr<URL> fullURL() const = 0;
    virtual URL urlForQueryReplacement() const = 0;
    virtual ExceptionOr<void> setFullURL(const URL&) = 0;
};

} // namespace WebCore
