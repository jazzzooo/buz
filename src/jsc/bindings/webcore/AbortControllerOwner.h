#pragma once

#include "AbortController.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSAbortControllerOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, AbortController*)
{
    static NeverDestroyed<JSAbortControllerOwner> owner;
    return &owner.get();
}

} // namespace WebCore
