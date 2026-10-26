/*
 * Copyright (C) 2005, 2007, 2015 Apple Inc. All rights reserved.
 * Copyright (C) 2006 Jon Shier (jshier@iastate.edu)
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
 *
 */

#pragma once

#include <memory>
#include <wtf/text/AtomString.h>

namespace WebCore {

#define DOM_EVENT_NAMES_FOR_EACH(macro) \
    macro(error)                       \
    macro(abort)                       \
    macro(close)                       \
    macro(open)                        \
    macro(rename)                      \
    macro(message)                     \
    macro(change)                      \
    macro(messageerror)                \
    macro(resourcetimingbufferfull)

struct EventNames {
    WTF_MAKE_NONCOPYABLE(EventNames);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(EventNames);

public:
#define DOM_EVENT_NAMES_DECLARE(name) const AtomString name##Event { #name##_s };
    DOM_EVENT_NAMES_FOR_EACH(DOM_EVENT_NAMES_DECLARE)
#undef DOM_EVENT_NAMES_DECLARE

    static std::unique_ptr<EventNames> create()
    {
        return std::unique_ptr<EventNames>(new EventNames);
    }

private:
    EventNames() = default;
};

const EventNames& eventNames();

} // namespace WebCore
