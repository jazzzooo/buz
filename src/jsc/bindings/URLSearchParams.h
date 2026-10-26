/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
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
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once
#include "root.h"

#include "ExceptionOr.h"
#include <wtf/Vector.h>
#include <wtf/RefPtr.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class DOMURL;
class ScriptExecutionContext;

class URLSearchParams : public RefCounted<URLSearchParams> {
public:
    ~URLSearchParams();

    static ExceptionOr<Ref<URLSearchParams>> create(StringView);
    static ExceptionOr<Ref<URLSearchParams>> create(Vector<KeyValuePair<String, String>>&&);

    ExceptionOr<void> append(const String& name, const String& value);
    ExceptionOr<void> remove(const StringView name, const String& value = {});
    String get(const StringView name) const;
    ExceptionOr<Vector<String>> getAll(const StringView name) const;
    bool has(const StringView name, const String& value = {}) const;
    ExceptionOr<void> set(const String& name, const String& value);
    ExceptionOr<String> toString() const;
    ExceptionOr<void> sort();
    size_t size() const { return m_pairs.size(); }
    const Vector<KeyValuePair<String, String>>& pairs() const { return m_pairs; }
    size_t memoryCost() const;

    class Iterator {
    public:
        explicit Iterator(URLSearchParams&);
        std::optional<KeyValuePair<String, String>> next();

    private:
        Ref<URLSearchParams> m_target;
        size_t m_index { 0 };
    };
    Iterator createIterator() { return Iterator { *this }; }
    Iterator createIterator(const ScriptExecutionContext* context) { return Iterator { *this }; }

private:
    friend class DOMURL;
    static ExceptionOr<Ref<URLSearchParams>> createFromQuery(StringView);
    explicit URLSearchParams(Vector<KeyValuePair<String, String>>&&);
    template<typename Mutate> ExceptionOr<void> mutatePairs(Mutate&&);

    Vector<KeyValuePair<String, String>> m_pairs;
    // A DOMURL owns its params; invalidation needs no back-reference to that owner.
    bool m_queryDirty { false };
};

} // namespace WebCore
