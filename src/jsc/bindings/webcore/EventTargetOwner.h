#pragma once

#include "AddEventListenerOptions.h"
#include "EventTarget.h"
#include "BunWorkerGlobalScope.h"
#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/WeakHandleOwner.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RefPtr.h>

namespace Bun::Bindgen {

class AddEventListenerOptionsInput;
class RemoveEventListenerOptionsInput;

WebCore::EventTarget::AddEventListenerOptionsOrBoolean materializeEventListenerOptions(const AddEventListenerOptionsInput&);
WebCore::EventTarget::EventListenerOptionsOrBoolean materializeEventListenerOptions(const RemoveEventListenerOptionsInput&);
WTF::RefPtr<WebCore::EventListener> createEventListener(JSC::JSGlobalObject&, JSC::JSObject* listener, JSC::JSObject& receiver);

template<typename Listener>
JSC::JSValue eventListenerValue(const Listener& value)
{
    if (value.is_listener())
        return value.listener();
    if (value.is_null_value())
        return JSC::jsNull();
    RELEASE_ASSERT(value.is_undefined_value());
    return JSC::jsUndefined();
}

template<typename Listener>
WTF::RefPtr<WebCore::EventListener> createEventListener(JSC::JSGlobalObject& globalObject, const Listener& value, JSC::JSObject& receiver)
{
    return createEventListener(globalObject, value.is_listener() ? JSC::asObject(value.listener()) : nullptr, receiver);
}
} // namespace Bun::Bindgen

namespace WebCore {

class DOMWrapperWorld;

class JSEventTargetOwner final : public JSC::WeakHandleOwner {
public:
    bool isReachableFromOpaqueRoots(JSC::Handle<JSC::Unknown>, void*, JSC::AbstractSlotVisitor&, ASCIILiteral*) final;
    void finalize(JSC::Handle<JSC::Unknown>, void*) final;
};

inline JSC::WeakHandleOwner* wrapperOwner(DOMWrapperWorld&, EventTarget*)
{
    static NeverDestroyed<JSEventTargetOwner> owner;
    return &owner.get();
}

inline void* wrapperKey(EventTarget* object)
{
    return object;
}

} // namespace WebCore
