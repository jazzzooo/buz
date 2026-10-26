/*
 *  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
 *  Copyright (C) 2004, 2005, 2006, 2007, 2008, 2009 Apple Inc. All rights reserved.
 *  Copyright (C) 2007 Samuel Weinig <sam@webkit.org>
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "root.h"

#include "DOMWrapperWorld.h"

#include "WebCoreJSClientData.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/WeakInlines.h>
#include <limits>
#include <wtf/MainThread.h>

namespace WebCore {

using namespace JSC;

DOMWrapperWorld::DOMWrapperWorld(JSC::VM& vm)
    : m_vm(vm)
{
    VM::ClientData* clientData = m_vm.clientData;
    ASSERT(clientData);
    static_cast<JSVMClientData*>(clientData)->rememberWorld(*this);
}

DOMWrapperWorld::~DOMWrapperWorld()
{
    RELEASE_ASSERT(m_wrappers.isEmpty());
    VM::ClientData* clientData = m_vm.clientData;
    ASSERT(clientData);
    static_cast<JSVMClientData*>(clientData)->forgetWorld(*this);
}

JSC::JSObject* DOMWrapperWorld::getWrapper(void* native) const
{
    auto generation = static_cast<JSVMClientData*>(m_vm.clientData)->wrapperIdentity(native);
    return generation ? m_wrappers.get(generation) : nullptr;
}

void DOMWrapperWorld::cacheWrapper(void* native, JSC::JSObject* wrapper, JSC::WeakHandleOwner* owner)
{
    RELEASE_ASSERT(native && wrapper && owner);
    auto& clientData = *static_cast<JSVMClientData*>(m_vm.clientData);
    auto generation = clientData.wrapperIdentity(native);
    if (!generation || !m_wrappers.contains(generation)) {
        generation = clientData.retainWrapperIdentity(native);
        // Weak finalization can follow collection of the owning global.
        ref();
    }
    RELEASE_ASSERT(!m_wrappers.get(generation));
    // Replacing an unfinalized dead weak handle transfers its registration.
    weakAdd(m_wrappers, generation, JSC::Weak<JSC::JSObject>(wrapper, owner, this));
}

void DOMWrapperWorld::uncacheWrapper(void* native, JSC::JSObject* wrapper)
{
    auto& clientData = *static_cast<JSVMClientData*>(m_vm.clientData);
    auto generation = clientData.wrapperIdentity(native);
    RELEASE_ASSERT(generation);
    auto entry = m_wrappers.find(generation);
    RELEASE_ASSERT(entry != m_wrappers.end() && entry->value.was(wrapper));
    weakRemove(m_wrappers, generation, wrapper);
    clientData.releaseWrapperIdentity(native, generation);
    deref();
}

uint64_t JSVMClientData::wrapperIdentity(void* native) const
{
    auto entry = m_wrapperIdentities.find(native);
    return entry == m_wrapperIdentities.end() ? 0 : entry->value.generation;
}

uint64_t JSVMClientData::retainWrapperIdentity(void* native)
{
    RELEASE_ASSERT(native);
    auto entry = m_wrapperIdentities.ensure(native, [this] {
        RELEASE_ASSERT(m_nextWrapperIdentity < std::numeric_limits<uint64_t>::max());
        return WrapperIdentity { m_nextWrapperIdentity++, 0 };
    });
    auto& identity = entry.iterator->value;
    RELEASE_ASSERT(identity.registrations < std::numeric_limits<size_t>::max());
    ++identity.registrations;
    return identity.generation;
}

void JSVMClientData::releaseWrapperIdentity(void* native, uint64_t generation)
{
    auto entry = m_wrapperIdentities.find(native);
    RELEASE_ASSERT(entry != m_wrapperIdentities.end());
    auto& identity = entry->value;
    RELEASE_ASSERT(identity.generation == generation && identity.registrations);
    if (!--identity.registrations)
        m_wrapperIdentities.remove(entry);
}

void JSVMClientData::rememberWorld(DOMWrapperWorld& world)
{
    ASSERT(!world.m_previousWorld && !world.m_nextWorld);
    world.m_nextWorld = m_wrapperWorlds;
    if (m_wrapperWorlds)
        m_wrapperWorlds->m_previousWorld = &world;
    m_wrapperWorlds = &world;
}

void JSVMClientData::forgetWorld(DOMWrapperWorld& world)
{
    if (world.m_previousWorld)
        world.m_previousWorld->m_nextWorld = world.m_nextWorld;
    else {
        ASSERT(m_wrapperWorlds == &world);
        m_wrapperWorlds = world.m_nextWorld;
    }
    if (world.m_nextWorld)
        world.m_nextWorld->m_previousWorld = world.m_previousWorld;
    world.m_previousWorld = nullptr;
    world.m_nextWorld = nullptr;
    if (!m_wrapperWorlds)
        RELEASE_ASSERT(m_wrapperIdentities.isEmpty());
}

} // namespace WebCore
