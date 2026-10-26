/*
 * Copyright (C) 2010 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "DOMFormData.h"
#include "FormURLEncoding.h"
#include <algorithm>
#include "wtf/DebugHeap.h"
#include <wtf/SIMDUTF.h>

namespace WebCore {

DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(DOMFormData);

ExceptionOr<Ref<DOMFormData>> DOMFormData::create()
{
    auto* memory = DOMFormDataMalloc::tryMalloc(sizeof(DOMFormData));
    if (!memory)
        return Exception { OutOfMemoryError };
    return adoptRef(*new (memory) DOMFormData());
}

ExceptionOr<Ref<DOMFormData>> DOMFormData::create(std::span<const uint8_t> input)
{
    auto result = create();
    if (result.hasException())
        return result.releaseException();
    auto form = result.releaseReturnValue();
    auto parsed = FormURLEncoding::parse(input, [&](String&& name, String&& value) -> ExceptionOr<void> {
        if (!form->m_items.tryAppend(Item { WTF::move(name), WTF::move(value) }))
            return Exception { OutOfMemoryError };
        return {};
    });
    if (parsed.hasException())
        return parsed.releaseException();
    return form;
}

static ExceptionOr<String> normalizeFormString(const String& value)
{
    if (!hasUnpairedSurrogate(value))
        return String(value);
    std::span<char16_t> output;
    auto impl = StringImpl::tryCreateUninitialized(value.length(), output);
    if (!impl)
        return Exception { OutOfMemoryError };
    simdutf::to_well_formed_utf16(value.span16().data(), value.length(), output.data());
    return String(WTF::move(impl));
}

static ExceptionOr<DOMFormData::Item> createStringEntry(const String& name, const String& value)
{
    auto normalizedName = normalizeFormString(name);
    if (normalizedName.hasException())
        return normalizedName.releaseException();
    auto normalizedValue = normalizeFormString(value);
    if (normalizedValue.hasException())
        return normalizedValue.releaseException();
    return DOMFormData::Item { normalizedName.releaseReturnValue(), normalizedValue.releaseReturnValue() };
}

ExceptionOr<DOMFormData::PreparedMutation> DOMFormData::prepareAppend(const String& name, const String& value)
{
    auto entry = createStringEntry(name, value);
    if (entry.hasException())
        return entry.releaseException();
    return prepareMutation(entry.releaseReturnValue(), false);
}

static ExceptionOr<DOMFormData::Item> createFileEntry(const String& name, Ref<Blob> blob, const String& filename)
{
    auto normalizedName = normalizeFormString(name);
    if (normalizedName.hasException())
        return normalizedName.releaseException();
    auto normalizedFilename = normalizeFormString(filename);
    if (normalizedFilename.hasException())
        return normalizedFilename.releaseException();
    auto file = blob->withFileName(normalizedFilename.releaseReturnValue());
    if (file.hasException())
        return file.releaseException();
    return DOMFormData::Item { normalizedName.releaseReturnValue(), file.releaseReturnValue() };
}

ExceptionOr<DOMFormData::PreparedMutation> DOMFormData::prepareAppend(const String& name, Ref<Blob> blob, const String& filename)
{
    auto entry = createFileEntry(name, WTF::move(blob), filename);
    if (entry.hasException())
        return entry.releaseException();
    return prepareMutation(entry.releaseReturnValue(), false);
}

ExceptionOr<void> DOMFormData::append(const String& name, const String& value)
{
    auto prepared = prepareAppend(name, value);
    if (prepared.hasException())
        return prepared.releaseException();
    prepared.releaseReturnValue().commit();
    return {};
}

ExceptionOr<void> DOMFormData::append(const String& name, Ref<Blob> blob, const String& filename)
{
    auto prepared = prepareAppend(name, WTF::move(blob), filename);
    if (prepared.hasException())
        return prepared.releaseException();
    prepared.releaseReturnValue().commit();
    return {};
}

void DOMFormData::remove(const StringView name)
{
    RELEASE_ASSERT(!m_mutationPending);
    m_items.removeAllMatching([name](const auto& item) {
        return item.name == name;
    });
}

bool DOMFormData::has(const StringView name)
{
    for (auto& item : m_items) {
        if (item.name == name)
            return true;
    }

    return false;
}

ExceptionOr<DOMFormData::PreparedMutation> DOMFormData::prepareSet(const String& name, const String& value)
{
    auto entry = createStringEntry(name, value);
    if (entry.hasException())
        return entry.releaseException();
    return prepareMutation(entry.releaseReturnValue(), true);
}

ExceptionOr<DOMFormData::PreparedMutation> DOMFormData::prepareSet(const String& name, Ref<Blob> blob, const String& filename)
{
    auto entry = createFileEntry(name, WTF::move(blob), filename);
    if (entry.hasException())
        return entry.releaseException();
    return prepareMutation(entry.releaseReturnValue(), true);
}

ExceptionOr<DOMFormData::PreparedMutation> DOMFormData::prepareMutation(Item&& item, bool replace)
{
    RELEASE_ASSERT(!m_mutationPending);
    if (replace) {
        for (size_t index = 0; index < m_items.size(); ++index) {
            if (item.name == m_items[index].name)
                return PreparedMutation { *this, WTF::move(item), index, true };
        }
    }
    if (!m_items.tryReserveCapacity(static_cast<size_t>(m_items.size()) + 1))
        return Exception { OutOfMemoryError };
    return PreparedMutation { *this, WTF::move(item), m_items.size(), false };
}

DOMFormData::PreparedMutation::PreparedMutation(DOMFormData& target, Item&& item, size_t index, bool replacesExisting)
    : m_target(target)
    , m_item(WTF::move(item))
    , m_index(index)
    , m_replacesExisting(replacesExisting)
{
    RELEASE_ASSERT(!target.m_mutationPending);
    target.m_mutationPending = true;
}

DOMFormData::PreparedMutation::PreparedMutation(PreparedMutation&& other)
    : m_target(WTF::move(other.m_target))
    , m_item(WTF::move(other.m_item))
    , m_index(other.m_index)
    , m_replacesExisting(other.m_replacesExisting)
{
}

DOMFormData::PreparedMutation::~PreparedMutation()
{
    if (m_target)
        m_target->m_mutationPending = false;
}

void DOMFormData::PreparedMutation::commit()
{
    RELEASE_ASSERT(m_target && m_target->m_mutationPending);
    auto& items = m_target->m_items;
    if (m_replacesExisting) {
        auto name = m_item.name;
        items[m_index] = WTF::move(m_item);
        items.removeAllMatching([&name](const auto& item) { return item.name == name; }, m_index + 1);
    } else {
        RELEASE_ASSERT(m_index == items.size());
        items.unsafeAppendWithoutCapacityCheck(WTF::move(m_item));
    }
    m_target->m_mutationPending = false;
    m_target = nullptr;
}

DOMFormData::Iterator::Iterator(DOMFormData& target)
    : m_target(target)
{
}

std::optional<KeyValuePair<String, DOMFormData::FormDataEntryValue>> DOMFormData::Iterator::next()
{
    auto& items = m_target->items();
    if (m_index >= items.size())
        return std::nullopt;

    auto& item = items[m_index++];
    return makeKeyValuePair(item.name, item.data);
}

size_t DOMFormData::memoryCost() const
{
    size_t cost = m_items.sizeInBytes();
    for (auto& item : m_items) {
        cost += item.name.sizeInBytes();
        if (auto value = std::get_if<Ref<Blob>>(&item.data)) {
            cost += (*value)->memoryCost();
        } else if (auto value = std::get_if<String>(&item.data)) {
            cost += value->sizeInBytes();
        }
    }

    return cost;
}

} // namespace WebCore
