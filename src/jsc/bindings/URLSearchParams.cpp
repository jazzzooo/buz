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

#include "URLSearchParams.h"
#include "SchemaBindings.h"

#include "FormURLEncoding.h"
#include <new>

void Bun::Bindgen::Engine::releaseURLSearchParams(WebCore::URLSearchParams* params)
{
    params->deref();
}

WebCore::URLSearchParams* Bun::Bindgen::Engine::bunBindgenEngine_urls_urlSearchParamsRetain(
    const BunBindgenEngine_urls_urlSearchParamsRetain_Arguments& args)
{
    args.params->ref();
    return args.params;
}

uint64_t Bun::Bindgen::Engine::bunBindgenEngine_urls_urlSearchParamsMemoryCost(
    const BunBindgenEngine_urls_urlSearchParamsMemoryCost_Arguments& args)
{
    return args.params->memoryCost();
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlSearchParamsToString_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlSearchParamsToString(
    const BunBindgenEngine_urls_urlSearchParamsToString_Arguments& args)
{
    auto result = args.params->toString();
    if (result.hasException()) {
        RELEASE_ASSERT(result.releaseException().code() == WebCore::OutOfMemoryError);
        return Bun::Bindgen::nativeAllocationFailure();
    }
    return result.releaseReturnValue();
}

void Bun::Bindgen::Engine::releaseURLSearchParamsIterator(WebCore::URLSearchParams::Iterator* iterator)
{
    delete iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlSearchParamsIteratorCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlSearchParamsIteratorCreate(
    const BunBindgenEngine_urls_urlSearchParamsIteratorCreate_Arguments& args)
{
    auto* iterator = new (std::nothrow) WebCore::URLSearchParams::Iterator(*args.params);
    if (!iterator)
        return Bun::Bindgen::nativeAllocationFailure();
    return iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_urls_urlSearchParamsIteratorNext_Return Bun::Bindgen::Engine::bunBindgenEngine_urls_urlSearchParamsIteratorNext(
    const BunBindgenEngine_urls_urlSearchParamsIteratorNext_Arguments& args)
{
    auto entry = args.iterator->next();
    if (!entry)
        return std::nullopt;
    using Entry = BunBindgenEngine_urls_urlSearchParamsIteratorNext_Return::value_type::value_type;
    return Entry { .key = WTF::move(entry->key), .value = WTF::move(entry->value) };
}

namespace WebCore {

URLSearchParams::URLSearchParams(Vector<KeyValuePair<String, String>>&& pairs)
    : m_pairs(WTF::move(pairs))
{
}

URLSearchParams::~URLSearchParams() = default;

ExceptionOr<Ref<URLSearchParams>> URLSearchParams::create(StringView input)
{
    return createFromQuery(input.startsWith('?') ? input.substring(1) : input);
}

ExceptionOr<Ref<URLSearchParams>> URLSearchParams::createFromQuery(StringView query)
{
    auto pairs = FormURLEncoding::parse(query);
    if (pairs.hasException())
        return pairs.releaseException();
    return create(pairs.releaseReturnValue());
}

ExceptionOr<Ref<URLSearchParams>> URLSearchParams::create(Vector<KeyValuePair<String, String>>&& pairs)
{
    void* storage;
    if (!WTF::tryFastMalloc(sizeof(URLSearchParams)).getValue(storage))
        return Exception { OutOfMemoryError };
    auto* params = new (NotNull, storage) URLSearchParams(WTF::move(pairs));
    return adoptRef(*params);
}

String URLSearchParams::get(const StringView name) const
{
    for (const auto& pair : m_pairs) {
        if (pair.key == name)
            return pair.value;
    }
    return String();
}

bool URLSearchParams::has(const StringView name, const String& value) const
{
    for (const auto& pair : m_pairs) {
        if (pair.key == name && (value.isNull() || pair.value == value))
            return true;
    }
    return false;
}

template<typename Mutate>
ExceptionOr<void> URLSearchParams::mutatePairs(Mutate&& mutate)
{
    auto result = mutate(m_pairs);
    if (result.hasException())
        return result.releaseException();
    m_queryDirty = true;
    return {};
}

ExceptionOr<void> URLSearchParams::sort()
{
    Vector<size_t> order;
    if (!order.tryGrow(m_pairs.size()))
        return Exception { OutOfMemoryError };
    for (size_t index = 0; index < order.size(); ++index)
        order[index] = index;
    if (order.size() > 1) {
        std::sort(order.begin(), order.end(), [&](size_t left, size_t right) {
            const auto& a = m_pairs[left].key;
            const auto& b = m_pairs[right].key;
            for (unsigned index = 0; index < std::min(a.length(), b.length()); ++index) {
                if (a[index] != b[index])
                    return a[index] < b[index];
            }
            return a.length() != b.length() ? a.length() < b.length() : left < right;
        });
    }
    Vector<KeyValuePair<String, String>> next;
    if (!next.tryReserveInitialCapacity(m_pairs.size()))
        return Exception { OutOfMemoryError };
    for (size_t index : order)
        next.unsafeAppendWithoutCapacityCheck(m_pairs[index]);
    m_pairs = WTF::move(next);
    m_queryDirty = true;
    return {};
}

ExceptionOr<void> URLSearchParams::set(const String& name, const String& value)
{
    return mutatePairs([&](auto& pairs) -> ExceptionOr<void> {
        for (size_t index = 0; index < pairs.size(); ++index) {
            if (pairs[index].key != name)
                continue;
            pairs[index].value = value;
            pairs.removeAllMatching([&](const auto& pair) { return pair.key == name; }, index + 1);
            return {};
        }
        if (!pairs.tryAppend(KeyValuePair<String, String> { name, value }))
            return Exception { OutOfMemoryError };
        return {};
    });
}

ExceptionOr<void> URLSearchParams::append(const String& name, const String& value)
{
    return mutatePairs([&](auto& pairs) -> ExceptionOr<void> {
        if (!pairs.tryAppend(KeyValuePair<String, String> { name, value }))
            return Exception { OutOfMemoryError };
        return {};
    });
}

ExceptionOr<Vector<String>> URLSearchParams::getAll(const StringView name) const
{
    Vector<String> values;
    const size_t count = std::ranges::count_if(m_pairs, [&](const auto& pair) { return pair.key == name; });
    if (!values.tryReserveInitialCapacity(count))
        return Exception { OutOfMemoryError };
    for (const auto& pair : m_pairs) {
        if (pair.key == name)
            values.unsafeAppendWithoutCapacityCheck(pair.value);
    }
    return values;
}

ExceptionOr<void> URLSearchParams::remove(const StringView name, const String& value)
{
    return mutatePairs([&](auto& pairs) -> ExceptionOr<void> {
        pairs.removeAllMatching([&](const auto& pair) {
            return pair.key == name && (value.isNull() || pair.value == value);
        });
        return {};
    });
}

ExceptionOr<String> URLSearchParams::toString() const
{
    return FormURLEncoding::serialize(m_pairs.span());
}

std::optional<KeyValuePair<String, String>> URLSearchParams::Iterator::next()
{
    auto& pairs = m_target->pairs();
    if (m_index >= pairs.size())
        return std::nullopt;

    auto& pair = pairs[m_index++];
    return KeyValuePair<String, String> { pair.key, pair.value };
}

URLSearchParams::Iterator::Iterator(URLSearchParams& params)
    : m_target(params)
{
}

size_t URLSearchParams::memoryCost() const
{
    size_t cost = sizeof(URLSearchParams);
    for (const auto& pair : m_pairs) {
        cost += pair.key.sizeInBytes();
        cost += pair.value.sizeInBytes();
    }
    return cost;
}
}
