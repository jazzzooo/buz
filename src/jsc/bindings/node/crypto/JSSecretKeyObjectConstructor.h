#pragma once

#include "root.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/InternalFunction.h>

namespace Bun {

class JSSecretKeyObjectConstructor final : public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static JSSecretKeyObjectConstructor* create(JSC::VM& vm, JSC::Structure* structure, JSC::JSObject* prototype)
    {
        JSSecretKeyObjectConstructor* constructor = new (NotNull, JSC::allocateCell<JSSecretKeyObjectConstructor>(vm)) JSSecretKeyObjectConstructor(vm, structure);
        constructor->finishCreation(vm, prototype);
        return constructor;
    }

    DECLARE_INFO;

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.internalFunctionSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
    }

private:
    JSSecretKeyObjectConstructor(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure, bun_bindgen_host_NodeCryptoBinding_secretKeyObjectConstructorCall, bun_bindgen_host_NodeCryptoBinding_secretKeyObjectConstructorConstruct)
    {
    }

    void finishCreation(JSC::VM& vm, JSC::JSObject* prototype)
    {
        Base::finishCreation(vm, 2, "SecretKeyObject"_s);
        putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly);
    }
};

} // namespace Bun
