/*
 *  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
 *  Copyright (C) 2003-2006, 2008-2009, 2013, 2016 Apple Inc. All rights reserved.
 *  Copyright (C) 2007 Samuel Weinig <sam@webkit.org>
 *  Copyright (C) 2009 Google, Inc. All rights reserved.
 *  Copyright (C) 2012 Ericsson AB. All rights reserved.
 *  Copyright (C) 2013 Michael Pruett <michael@68k.org>
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

#pragma once

#include "DOMWrapperWorld.h"
#include "JSDOMGlobalObject.h"
#include "JSDOMWrapper.h"
#include "ScriptWrappable.h"
#include "WebCoreTypedArrayController.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/Weak.h>
#include <JavaScriptCore/WeakInlines.h>

namespace WebCore {

JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, JSC::ArrayBuffer*);

template<typename T> inline void* wrapperKey(T* object)
{
    return object;
}

template<typename DOMClass> JSC::JSObject* getOrCreateWrapper(DOMWrapperWorld&, DOMClass&);

template<typename DOMClass> JSC::JSObject* getCachedWrapper(DOMWrapperWorld&, DOMClass&);
template<typename DOMClass> inline JSC::JSObject* getCachedWrapper(DOMWrapperWorld& world, Ref<DOMClass>& object) { return getCachedWrapper(world, object.get()); }
template<typename DOMClass, typename WrapperClass> void cacheWrapper(DOMWrapperWorld&, DOMClass*, WrapperClass*);
template<typename DOMClass, typename WrapperClass> void uncacheWrapper(DOMWrapperWorld&, DOMClass*, WrapperClass*);

template<typename DOMClass> JSC::JSValue wrap(JSC::JSGlobalObject*, DOMWrapperWorld&, DOMClass&);
template<typename DOMClass> JSC::JSValue wrap(JSC::JSGlobalObject*, JSDOMGlobalObject*, DOMClass&);

// Inline functions and template definitions.

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld& world, JSC::ArrayBuffer*)
{
    return static_cast<WebCoreTypedArrayController*>(world.vm().m_typedArrayController.get())->wrapperOwner();
}

template<typename DOMClass> inline JSC::JSObject* getCachedWrapper(DOMWrapperWorld& world, DOMClass& domObject)
{
    return world.getWrapper(wrapperKey(&domObject));
}

template<typename DOMClass, typename WrapperClass> inline void cacheWrapper(DOMWrapperWorld& world, DOMClass* domObject, WrapperClass* wrapper)
{
    world.cacheWrapper(wrapperKey(domObject), wrapper, wrapperOwner(world, domObject));
}

template<typename DOMClass, typename Function> inline void forEachCachedWrapper(DOMWrapperWorld* worlds, DOMClass& object, const Function& function)
{
    for (auto* world = worlds; world; world = world->nextWorld()) {
        if (auto* wrapper = getCachedWrapper(*world, object))
            function(wrapper);
    }
}

template<typename DOMClass> inline void writeBarrierForWrappers(JSC::VM& vm, DOMWrapperWorld* worlds, DOMClass& object)
{
    forEachCachedWrapper(worlds, object, [&vm](JSC::JSObject* wrapper) {
        vm.writeBarrier(wrapper);
    });
}

template<typename DOMClass, typename WrapperClass> inline void uncacheWrapper(DOMWrapperWorld& world, DOMClass* domObject, WrapperClass* wrapper)
{
    world.uncacheWrapper(wrapperKey(domObject), wrapper);
}

template<typename DOMClass> inline JSC::JSValue wrap(JSC::JSGlobalObject* lexicalGlobalObject, JSDOMGlobalObject* globalObject, DOMClass& domObject)
{
    if (auto* wrapper = getCachedWrapper(globalObject->world(), domObject))
        return wrapper;
    return toJSNewlyCreated(lexicalGlobalObject, globalObject, Ref<DOMClass>(domObject));
}

} // namespace WebCore
