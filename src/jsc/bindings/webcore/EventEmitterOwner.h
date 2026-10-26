#pragma once

#include "EventEmitter.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSEventEmitterOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, EventEmitter*)
{
    static NeverDestroyed<JSEventEmitterOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(EventEmitter* object)
{
    return object;
}

} // namespace WebCore
