#pragma once

#include "root.h"

#include <wtf/Forward.h>
#include <wtf/HashMap.h>
#include <JavaScriptCore/Weak.h>

namespace WebCore {

class DOMWrapperWorld : public RefCounted<DOMWrapperWorld> {
public:
    static Ref<DOMWrapperWorld> create(JSC::VM& vm)
    {
        return adoptRef(*new DOMWrapperWorld(vm));
    }
    WEBCORE_EXPORT ~DOMWrapperWorld();

    JSC::JSObject* getWrapper(void* native) const;
    void cacheWrapper(void* native, JSC::JSObject*, JSC::WeakHandleOwner*);
    void uncacheWrapper(void* native, JSC::JSObject*);

    JSC::VM& vm() const { return m_vm; }
    DOMWrapperWorld* nextWorld() const { return m_nextWorld; }

protected:
    explicit DOMWrapperWorld(JSC::VM&);

private:
    friend class JSVMClientData;
    DOMWrapperWorld* m_previousWorld { nullptr };
    DOMWrapperWorld* m_nextWorld { nullptr };
    JSC::VM& m_vm;
    HashMap<uint64_t, JSC::Weak<JSC::JSObject>> m_wrappers;
};

} // namespace WebCore
