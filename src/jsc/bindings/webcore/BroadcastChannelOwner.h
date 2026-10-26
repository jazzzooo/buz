#pragma once

// Wrapper-owner contract for the generated BroadcastChannel wrapper. The
// generated toJS caches through this owner (found by argument-dependent
// lookup on the impl type), which keeps a channel with pending activity
// alive across GC even when nothing else references its wrapper.

#include "root.h"
#include "BroadcastChannel.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSBroadcastChannelOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, BroadcastChannel*)
{
    static NeverDestroyed<JSBroadcastChannelOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(BroadcastChannel* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
