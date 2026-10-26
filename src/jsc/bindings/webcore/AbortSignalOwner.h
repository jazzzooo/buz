#pragma once

// Wrapper-owner contract for the generated AbortSignal wrapper. The
// generated toJS caches through this owner (found by argument-dependent
// lookup on the impl type), which keeps a signal alive across GC while it
// can still fire abort events that JS observes.

#include "root.h"
#include "AbortSignal.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSAbortSignalOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, AbortSignal*)
{
    static NeverDestroyed<JSAbortSignalOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(AbortSignal* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
