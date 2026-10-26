#pragma once

namespace Zig {
class GlobalObject;
}

#include "root.h"
#include "SchemaBindingsWire.h"
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/VM.h>

#include "BunClientData.h"
#include <JavaScriptCore/CallFrame.h>

namespace JSC {
class JSGlobalObject;
}

namespace Zig {

using namespace JSC;

class JSFFIFunction final : public JSC::JSFunction {
public:
    using Base = JSFunction;

    static constexpr unsigned StructureFlags = Base::StructureFlags;
    static constexpr JSC::DestructionMode needsDestruction = DoesNotNeedDestruction;
    static void destroy(JSCell* cell)
    {
        static_cast<JSFFIFunction*>(cell)->JSFFIFunction::~JSFFIFunction();
    }

    template<typename, SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return WebCore::subspaceForImpl<JSFFIFunction, WebCore::UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForFFIFunction.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForFFIFunction = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForFFIFunction.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForFFIFunction = std::forward<decltype(space)>(space); });
    }

    DECLARE_EXPORT_INFO;

    JS_EXPORT_PRIVATE static JSFFIFunction* create(VM&, Zig::GlobalObject*, unsigned length, const String& name, NativeFunction);

    static Structure* createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
    {
        ASSERT(globalObject);
        return Structure::create(vm, globalObject, prototype, TypeInfo(JSFunctionType, StructureFlags), info());
    }

    BindNativeHandle* dataPtr { nullptr };

private:
    JSFFIFunction(VM&, NativeExecutable*, JSGlobalObject*, Structure*);
};

} // namespace Zig
