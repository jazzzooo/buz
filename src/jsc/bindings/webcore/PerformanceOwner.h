#pragma once

#include "Performance.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSPerformanceOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, Performance*)
{
    static NeverDestroyed<JSPerformanceOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(Performance* object)
{
    return object;
}

} // namespace WebCore
