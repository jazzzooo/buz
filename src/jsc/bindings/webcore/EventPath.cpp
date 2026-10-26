// /*
//  * Copyright (C) 2013 Google Inc. All rights reserved.
//  * Copyright (C) 2013-2022 Apple Inc. All rights reserved.
//  *
//  * This library is free software; you can redistribute it and/or
//  * modify it under the terms of the GNU Library General Public
//  * License as published by the Free Software Foundation; either
//  * version 2 of the License, or (at your option) any later version.
//  *
//  * This library is distributed in the hope that it will be useful,
//  * but WITHOUT ANY WARRANTY; without even the implied warranty of
//  * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  * Library General Public License for more details.
//  *
//  * You should have received a copy of the GNU Library General Public License
//  * along with this library; see the file COPYING.LIB.  If not, write to
//  * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  * Boston, MA 02110-1301, USA.
//  */

#include "config.h"
#include "EventPath.h"

namespace WebCore {

// https://dom.spec.whatwg.org/#dom-event-composedpath
Vector<Ref<EventTarget>> EventPath::computePathUnclosedToTarget(const EventTarget& target) const
{
    RELEASE_ASSERT(&target == &m_target.get());
    Vector<Ref<EventTarget>> path;
    path.reserveInitialCapacity(1);
    path.append(m_target.copyRef());
    return path;
}

EventPath::EventPath(EventTarget& target)
    : m_target(target)
{
}

}
