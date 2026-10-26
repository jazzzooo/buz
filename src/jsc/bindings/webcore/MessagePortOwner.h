#pragma once

// Wrapper-owner contract for the generated MessagePort wrapper. The
// generated toJS caches through this owner (found by argument-dependent
// lookup on the impl type), which keeps a port with pending activity or a
// live entangled peer alive across GC.

#include "root.h"
#include "MessagePort.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSMessagePortOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, MessagePort*)
{
    static NeverDestroyed<JSMessagePortOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(MessagePort* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
