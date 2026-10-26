#pragma once

// Wrapper-owner contract for the generated Worker wrapper. The generated
// toJS caches through this owner (found by argument-dependent lookup on the
// impl type), which keeps a running worker's wrapper alive across GC.

#include "root.h"
#include "Worker.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSWorkerOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, Worker*)
{
    static NeverDestroyed<JSWorkerOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(Worker* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
