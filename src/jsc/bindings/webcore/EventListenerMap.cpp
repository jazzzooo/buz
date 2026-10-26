/*
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 *           (C) 1999 Antti Koivisto (koivisto@kde.org)
 *           (C) 2001 Dirk Mueller (mueller@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2007 Apple Inc. All rights reserved.
 * Copyright (C) 2006 Alexey Proskuryakov (ap@webkit.org)
 *           (C) 2007, 2008 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2011 Andreas Kling (kling@webkit.org)
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
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include "config.h"
#include "EventListenerMap.h"

#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>

namespace WebCore {

EventListenerMap::EventListenerMap() = default;

EventListenerMap::~EventListenerMap()
{
    ASSERT(!m_dispatchCursors);
}

EventListenerMap::DispatchCursor::DispatchCursor(EventListenerMap& map, const AtomString& eventType)
    : m_map(map)
    , m_eventType(eventType)
{
    m_map.releaseAssertOrSetThreadUID();
    Locker locker { m_map.m_lock };
    if (auto* listeners = m_map.find(eventType))
        m_end = listeners->size();
    m_next = m_map.m_dispatchCursors;
    if (m_next)
        m_next->m_previous = this;
    m_map.m_dispatchCursors = this;
}

EventListenerMap::DispatchCursor::~DispatchCursor()
{
    Locker locker { m_map.m_lock };
    if (m_previous)
        m_previous->m_next = m_next;
    else
        m_map.m_dispatchCursors = m_next;
    if (m_next)
        m_next->m_previous = m_previous;
}

RefPtr<RegisteredEventListener> EventListenerMap::DispatchCursor::next()
{
    Locker locker { m_map.m_lock };
    if (m_position == m_end)
        return nullptr;
    auto* listeners = m_map.find(m_eventType);
    RELEASE_ASSERT(listeners && m_position < m_end && m_end <= listeners->size());
    return (*listeners)[m_position++];
}

bool EventListenerMap::containsCapturing(const AtomString& eventType) const
{
    auto* listeners = find(eventType);
    if (!listeners)
        return false;

    for (auto& eventListener : *listeners) {
        if (eventListener->useCapture())
            return true;
    }
    return false;
}

bool EventListenerMap::containsActive(const AtomString& eventType) const
{
    auto* listeners = find(eventType);
    if (!listeners)
        return false;

    for (auto& eventListener : *listeners) {
        if (!eventListener->isPassive())
            return true;
    }
    return false;
}

void EventListenerMap::clear()
{
    takeAll();
}

EventListenerMap::Entries EventListenerMap::takeAll()
{
    releaseAssertOrSetThreadUID();
    Entries removed;
    {
        Locker locker { m_lock };
        for (auto* cursor = m_dispatchCursors; cursor; cursor = cursor->m_next) {
            cursor->m_position = 0;
            cursor->m_end = 0;
        }
        removed = WTF::move(m_entries);
    }

    for (auto& entry : removed) {
        for (auto& listener : entry.second)
            listener->markAsRemoved();
    }

    return removed;
}

Vector<AtomString> EventListenerMap::eventTypes() const
{
    return m_entries.map([](auto& entry) {
        return entry.first;
    });
}

static inline size_t findListener(const EventListenerVector& listeners, EventListener& listener, bool useCapture)
{
    for (size_t i = 0; i < listeners.size(); ++i) {
        auto& registeredListener = listeners[i];
        if (registeredListener->callback() == listener && registeredListener->useCapture() == useCapture)
            return i;
    }
    return notFound;
}

Bun::Bindgen::NativeAllocationResult<RegisteredEventListener*> EventListenerMap::add(const AtomString& eventType, Ref<EventListener>&& listener, const RegisteredEventListener::Options& options)
{
    releaseAssertOrSetThreadUID();
    Locker locker { m_lock };

    if (auto* listeners = findMutable(eventType)) {
        if (findListener(*listeners, listener, options.capture) != notFound)
            return nullptr; // Duplicate listener.
        auto registeredListener = RegisteredEventListener::tryCreate(WTF::move(listener), options);
        if (!registeredListener)
            return Bun::Bindgen::nativeAllocationFailure();
        auto* result = registeredListener.get();
        if (!listeners->tryAppend(WTF::move(registeredListener)))
            return Bun::Bindgen::nativeAllocationFailure();
        return result;
    }

    auto registeredListener = RegisteredEventListener::tryCreate(WTF::move(listener), options);
    if (!registeredListener)
        return Bun::Bindgen::nativeAllocationFailure();
    auto* result = registeredListener.get();
    EventListenerVector listeners;
    if (!listeners.tryAppend(WTF::move(registeredListener)))
        return Bun::Bindgen::nativeAllocationFailure();
    if (!m_entries.tryAppend(std::make_pair(eventType, WTF::move(listeners))))
        return Bun::Bindgen::nativeAllocationFailure();
    return result;
}

bool EventListenerMap::remove(const AtomString& eventType, EventListener& listener, bool useCapture)
{
    releaseAssertOrSetThreadUID();
    RefPtr<RegisteredEventListener> removed;
    {
        Locker locker { m_lock };
        for (size_t i = 0; i < m_entries.size(); ++i) {
            if (m_entries[i].first != eventType)
                continue;
            auto& listeners = m_entries[i].second;
            const size_t index = findListener(listeners, listener, useCapture);
            if (index == notFound)
                return false;
            removed = WTF::move(listeners[index]);
            // Insertions never extend a cursor's original snapshot boundary.
            for (auto* cursor = m_dispatchCursors; cursor; cursor = cursor->m_next) {
                if (cursor->m_eventType != eventType)
                    continue;
                if (index < cursor->m_position)
                    --cursor->m_position;
                if (index < cursor->m_end)
                    --cursor->m_end;
            }
            listeners.removeAt(index);
            if (listeners.isEmpty())
                m_entries.removeAt(i);
            break;
        }
    }

    if (!removed)
        return false;
    removed->markAsRemoved();
    return true;
}

EventListenerVector* EventListenerMap::findMutable(const AtomString& eventType)
{
    for (auto& entry : m_entries) {
        if (entry.first == eventType)
            return &entry.second;
    }

    return nullptr;
}

} // namespace WebCore
