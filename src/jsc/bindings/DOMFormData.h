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

#pragma once

#include "ExceptionOr.h"
#include <variant>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/text/WTFString.h>
#include "blob.h"

namespace WebCore {

DECLARE_ALLOCATOR_WITH_HEAP_IDENTIFIER(DOMFormData);

class DOMFormData : public RefCounted<DOMFormData> {
    WTF_MAKE_NONCOPYABLE(DOMFormData);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED_WITH_HEAP_IDENTIFIER(DOMFormData, DOMFormData);

public:
    using FormDataEntryValue = std::variant<String, Ref<Blob>>;

    struct Item {
        String name;
        FormDataEntryValue data;
    };

    // A preparation may span allocation, but must not span reentrant JavaScript.
    class PreparedMutation {
        WTF_MAKE_NONCOPYABLE(PreparedMutation);

    public:
        PreparedMutation(PreparedMutation&&);
        ~PreparedMutation();

        const Item& item() const { RELEASE_ASSERT(m_target); return m_item; }
        size_t index() const { return m_index; }
        void commit();

    private:
        friend class DOMFormData;
        PreparedMutation(DOMFormData&, Item&&, size_t index, bool replacesExisting);

        RefPtr<DOMFormData> m_target;
        Item m_item;
        size_t m_index;
        bool m_replacesExisting;
    };

    static ExceptionOr<Ref<DOMFormData>> create();
    static ExceptionOr<Ref<DOMFormData>> create(std::span<const uint8_t> urlEncodedBytes);

    const Vector<Item>& items() const { return m_items; }
    ExceptionOr<PreparedMutation> prepareAppend(const String& name, const String& value);
    ExceptionOr<PreparedMutation> prepareAppend(const String& name, Ref<Blob>, const String& filename);
    ExceptionOr<PreparedMutation> prepareSet(const String& name, const String& value);
    ExceptionOr<PreparedMutation> prepareSet(const String& name, Ref<Blob>, const String& filename);
    ExceptionOr<void> append(const String& name, const String& value);
    ExceptionOr<void> append(const String& name, Ref<Blob>, const String& filename);
    void remove(const StringView name);
    bool has(const StringView name);

    size_t count() const { return m_items.size(); }
    size_t memoryCost() const;

    class Iterator {
    public:
        explicit Iterator(DOMFormData&);
        size_t index() const { return m_index; }
        std::optional<KeyValuePair<String, FormDataEntryValue>> next();

    private:
        Ref<DOMFormData> m_target;
        size_t m_index { 0 };
    };

private:
    DOMFormData() = default;

    ExceptionOr<PreparedMutation> prepareMutation(Item&&, bool replace);

    Vector<Item> m_items;
    bool m_mutationPending { false };
};

} // namespace WebCore
