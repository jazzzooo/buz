#pragma once
#include <JavaScriptCore/Strong.h>
#include <memory>
#include <wtf/FastMalloc.h>
#include <wtf/RefCounted.h>

namespace Bun {

class StrongRefStorage final : public WTF::RefCounted<StrongRefStorage> {
public:
    StrongRefStorage(JSC::JSGlobalObject*, JSC::JSValue);
    void operator delete(void* reference) { WTF::fastFree(reference); }

    JSC::JSGlobalObject* globalObject() const { return m_global.get(); }
    JSC::JSValue value() const { return m_value.get(); }
    const JSC::JSValue* slot() const { return static_cast<const JSC::Handle<JSC::Unknown>&>(m_value).slot(); }

private:
    JSC::Strong<JSC::JSGlobalObject> m_global;
    JSC::Strong<JSC::Unknown> m_value;
};

struct StrongRefDeleter {
    void operator()(StrongRefStorage* reference) const { reference->deref(); }
};

using StrongRef = std::unique_ptr<StrongRefStorage, StrongRefDeleter>;

StrongRefStorage* createStrongRef(JSC::JSGlobalObject*, JSC::JSValue);

}
