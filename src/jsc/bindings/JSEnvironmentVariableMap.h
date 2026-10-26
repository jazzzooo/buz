#pragma once
#include "root.h"
#include "BunClientData.h"

namespace Zig {
class GlobalObject;
}

namespace JSC {
class JSValue;
}

namespace Bun {

class JSEnvironmentVariableMap final : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;
    static constexpr unsigned StructureFlags = Base::StructureFlags | JSC::OverridesPut;

    static JSEnvironmentVariableMap* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        auto* structure = JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        auto* object = new (NotNull, JSC::allocateCell<JSEnvironmentVariableMap>(vm)) JSEnvironmentVariableMap(vm, structure);
        object->finishCreation(vm);
        return object;
    }

    DECLARE_INFO;

    template<typename, JSC::SubspaceAccess mode>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<JSEnvironmentVariableMap, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForJSEnvironmentVariableMap.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForJSEnvironmentVariableMap = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForJSEnvironmentVariableMap.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForJSEnvironmentVariableMap = std::forward<decltype(space)>(space); });
    }

protected:
    static bool defineOwnProperty(JSC::JSObject*, JSC::JSGlobalObject*, JSC::PropertyName, const JSC::PropertyDescriptor&, bool shouldThrow);
    static bool put(JSC::JSCell*, JSC::JSGlobalObject*, JSC::PropertyName, JSC::JSValue, JSC::PutPropertySlot&);
    static bool deleteProperty(JSC::JSCell*, JSC::JSGlobalObject*, JSC::PropertyName, JSC::DeletePropertySlot&);

private:
    JSEnvironmentVariableMap(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }
};

JSC::JSValue createEnvironmentVariablesMap(Zig::GlobalObject* globalObject);

}
