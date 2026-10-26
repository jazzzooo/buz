#pragma once

#include "root.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "DOMWrapperWorld-class.h"

namespace Bun {

using namespace JSC;

class GlobalScope : public JSC::JSGlobalObject {
    using Base = JSC::JSGlobalObject;

protected:
    void finishCreation(JSC::VM& vm);

public:
    GlobalScope(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
        , m_world(WebCore::DOMWrapperWorld::create(vm))
    {
    }

    GlobalScope(JSC::VM& vm, JSC::Structure* structure, const JSC::GlobalObjectMethodTable* methodTable)
        : Base(vm, structure, methodTable)
        , m_world(WebCore::DOMWrapperWorld::create(vm))
    {
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSC::Structure* encodeIntoObjectStructure() const { return m_encodeIntoObjectStructure.getInitializedOnMainThread(this); }
    WebCore::DOMWrapperWorld& world() const { return m_world.get(); }

    /**
     * WARNING: You must update visitChildrenImpl() if you add a new field.
     *
     * That informs the garbage collector that these fields exist. If you don't
     * do that, the garbage collector will not know about these fields and will
     * not trace them. This will lead to crashes and very strange behavior at runtime.
     *
     * For example, if you don't add the queueMicrotask functions to visitChildrenImpl(),
     * those callbacks will eventually never be called anymore. But it'll work the first time!
     */
    LazyProperty<JSGlobalObject, Structure> m_encodeIntoObjectStructure;

private:
    Ref<WebCore::DOMWrapperWorld> m_world;
};

} // namespace Bun
