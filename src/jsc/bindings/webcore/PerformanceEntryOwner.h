#pragma once

// Wrapper-owner contract shared by every PerformanceEntry wrapper. The
// generated toJS of each subclass caches through this owner, found by
// argument-dependent lookup after the subclass pointer converts to
// PerformanceEntry*. Also pulls in the concrete entry types so the generated
// wrapper cells can complete their Ref<> members.

#include "root.h"
#include "PerformanceEntry.h"
#include "PerformanceMark.h"
#include "PerformanceMeasure.h"
#include "PerformanceResourceTiming.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSPerformanceEntryOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, PerformanceEntry*)
{
    static NeverDestroyed<JSPerformanceEntryOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(PerformanceEntry* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
