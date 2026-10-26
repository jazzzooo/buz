/*
 * Copyright (C) 2013 Google Inc. All rights reserved.
 * Copyright (C) 2013-2017 Apple Inc. All rights reserved.
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

#pragma once

#include "EventTarget.h"
#include <wtf/Ref.h>
#include <wtf/Vector.h>

namespace WebCore {

class EventPath {
public:
    explicit EventPath(EventTarget&);

    EventTarget& target() const { return m_target.get(); }
    Vector<Ref<EventTarget>> computePathUnclosedToTarget(const EventTarget&) const;

private:
    // Retain the dispatch target independently of Event's mutable target fields.
    Ref<EventTarget> m_target;
};

} // namespace WebCore
