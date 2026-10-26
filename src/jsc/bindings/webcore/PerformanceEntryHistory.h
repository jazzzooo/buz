#pragma once

#include "PerformanceEntry.h"
#include <limits>
#include <utility>
#include <wtf/Vector.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

class PerformanceEntryHistory {
    WTF_MAKE_NONCOPYABLE(PerformanceEntryHistory);

public:
    using Entries = Vector<RefPtr<PerformanceEntry>>;

    PerformanceEntryHistory() = default;

    bool tryAdd(PerformanceEntry& entry)
    {
        if (auto* slot = findSlot(entry.name()))
            return slot->entries.tryAppend(&entry);

        Entries entries;
        if (!entries.tryAppend(&entry) || !reserveOne())
            return false;

        const size_t mask = m_slots.size() - 1;
        size_t index = StringHash::hash(entry.name()) & mask;
        size_t deleted = std::numeric_limits<size_t>::max();
        while (m_slots[index].state != State::empty) {
            if (m_slots[index].state == State::deleted && deleted == std::numeric_limits<size_t>::max())
                deleted = index;
            index = (index + 1) & mask;
        }
        if (deleted != std::numeric_limits<size_t>::max()) {
            index = deleted;
            --m_deleted;
        }
        auto& slot = m_slots[index];
        slot.name = entry.name();
        slot.entries = WTF::move(entries);
        slot.state = State::occupied;
        ++m_size;
        return true;
    }

    const Entries* find(const String& name) const
    {
        auto* slot = findSlot(name);
        return slot ? &slot->entries : nullptr;
    }

    void clear(const String& name)
    {
        if (name.isNull()) {
            m_size = 0;
            m_deleted = 0;
            m_slots.clear();
            return;
        }
        auto* slot = findSlot(name);
        if (!slot)
            return;
        slot->state = State::deleted;
        --m_size;
        ++m_deleted;
        slot->name = String {};
        slot->entries.clear();
    }

    bool tryAppendTo(Entries& output, const String& name = String {}) const
    {
        if (!name.isNull()) {
            const auto* entries = find(name);
            return !entries || output.tryAppend(entries->span());
        }
        for (const auto& slot : m_slots) {
            if (slot.state == State::occupied && !output.tryAppend(slot.entries.span()))
                return false;
        }
        return true;
    }

    size_t memoryCost() const
    {
        size_t size = m_slots.sizeInBytes();
        for (const auto& slot : m_slots) {
            if (slot.state != State::occupied)
                continue;
            size += slot.entries.sizeInBytes();
            for (const auto& entry : slot.entries)
                size += entry->memoryCost();
        }
        return size;
    }

private:
    enum class State : uint8_t { empty, occupied, deleted };

    struct Slot {
        State state { State::empty };
        String name;
        Entries entries;
    };

    const Slot* findSlot(const String& name) const
    {
        if (m_slots.isEmpty())
            return nullptr;
        const size_t mask = m_slots.size() - 1;
        size_t index = StringHash::hash(name) & mask;
        while (m_slots[index].state != State::empty) {
            const auto& slot = m_slots[index];
            if (slot.state == State::occupied && slot.name == name)
                return &slot;
            index = (index + 1) & mask;
        }
        return nullptr;
    }

    Slot* findSlot(const String& name)
    {
        return const_cast<Slot*>(std::as_const(*this).findSlot(name));
    }

    bool reserveOne()
    {
        if (!m_slots.isEmpty() && m_size + m_deleted < m_slots.size() / 2)
            return true;
        size_t capacity = m_slots.isEmpty() ? 8 : m_slots.size();
        if (m_size >= capacity / 2) {
            if (capacity > std::numeric_limits<size_t>::max() / 2)
                return false;
            capacity *= 2;
        }

        Vector<Slot> slots;
        if (!slots.tryReserveInitialCapacity(capacity))
            return false;
        slots.grow(capacity);
        for (auto& slot : m_slots) {
            if (slot.state != State::occupied)
                continue;
            size_t index = StringHash::hash(slot.name) & (capacity - 1);
            while (slots[index].state != State::empty)
                index = (index + 1) & (capacity - 1);
            slots[index] = WTF::move(slot);
        }
        m_slots.swap(slots);
        m_deleted = 0;
        return true;
    }

    Vector<Slot> m_slots;
    size_t m_size { 0 };
    size_t m_deleted { 0 };
};

}
