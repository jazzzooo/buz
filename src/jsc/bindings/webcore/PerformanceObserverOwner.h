#pragma once

// Wrapper-owner contract for the generated PerformanceObserver wrapper. The
// generated toJS caches through this owner, found by argument-dependent
// lookup on the impl type; a registered observer keeps its wrapper (and so
// its callback) alive.

#include "root.h"
#include "PerformanceObserver.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSPerformanceObserverOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, PerformanceObserver*)
{
    static NeverDestroyed<JSPerformanceObserverOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(PerformanceObserver* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
