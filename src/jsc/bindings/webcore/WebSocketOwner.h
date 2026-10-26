#pragma once

// Wrapper-owner contract for the generated WebSocket wrapper. The generated
// toJS caches through this owner (found by argument-dependent lookup on the
// impl type), which keeps a socket with pending activity or in-flight event
// dispatch alive across GC.

#include "root.h"
#include "WebSocket.h"
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>

namespace WebCore {

class DOMWrapperWorld;

class JSWebSocketOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void* context, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void* context) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, WebSocket*)
{
    static NeverDestroyed<JSWebSocketOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(WebSocket* wrappableObject)
{
    return wrappableObject;
}

} // namespace WebCore
