#pragma once

#include "WritableStream.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSWritableStreamOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, WritableStream*)
{
    static NeverDestroyed<JSWritableStreamOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(WritableStream* object)
{
    return object;
}

} // namespace WebCore
