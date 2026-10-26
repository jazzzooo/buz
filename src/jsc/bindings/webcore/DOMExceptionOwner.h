#pragma once

// Wrapper-owner contract for the generated DOMException wrapper. The
// generated toJS caches through this owner, found by argument-dependent
// lookup on the impl type.

#include "root.h"
#include "DOMException.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSDOMExceptionOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, DOMException*)
{
    static NeverDestroyed<JSDOMExceptionOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(DOMException* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
