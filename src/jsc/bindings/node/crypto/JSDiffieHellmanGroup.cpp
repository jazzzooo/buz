#include "JSDiffieHellmanGroup.h"
#include "JSDiffieHellmanGroupPrototype.h"
#include "JSDiffieHellmanGroupConstructor.h"
#include "DOMIsoSubspaces.h"
#include "ZigGlobalObject.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/LazyClassStructure.h>
#include <JavaScriptCore/LazyClassStructureInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/ObjectPrototype.h>

namespace Bun {

static JSDiffieHellmanGroup* diffieHellmanGroup(JSC::JSValue value)
{
    auto* result = dynamicDowncast<JSDiffieHellmanGroup>(value);
    RELEASE_ASSERT(result);
    return result;
}

const JSC::ClassInfo JSDiffieHellmanGroup::s_info = { "DiffieHellmanGroup"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSDiffieHellmanGroup) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanGroupInstance
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanGroupInstance

void JSDiffieHellmanGroup::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSDiffieHellmanGroupInstance_install(vm, info(), *this);

    m_sizeForGC = this->m_dh.size();
    vm.heap.reportExtraMemoryAllocated(this, m_sizeForGC);
}

template<typename Visitor>
void JSDiffieHellmanGroup::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSDiffieHellmanGroup* thisObject = uncheckedDowncast<JSDiffieHellmanGroup>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);

    visitor.reportExtraMemoryVisited(thisObject->m_sizeForGC);
}

DEFINE_VISIT_CHILDREN(JSDiffieHellmanGroup);

void setupDiffieHellmanGroupClassStructure(JSC::LazyClassStructure::Initializer& init)
{
    auto* prototypeStructure = JSDiffieHellmanGroupPrototype::createStructure(init.vm, init.global, init.global->objectPrototype());
    auto* prototype = JSDiffieHellmanGroupPrototype::create(init.vm, init.global, prototypeStructure);

    auto* constructorStructure = JSDiffieHellmanGroupConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());
    auto* constructor = JSDiffieHellmanGroupConstructor::create(init.vm, constructorStructure, prototype);

    auto* structure = JSDiffieHellmanGroup::createStructure(init.vm, init.global, prototype);
    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

int32_t Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupVerifyError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupVerifyError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto& dh = diffieHellmanGroup(args.bindingThis)->getImpl();
    auto result = dh.check();
    if (result == ncrypto::DHPointer::CheckResult::CHECK_FAILED) {
        ERR::CRYPTO_OPERATION_FAILED(scope, globalObject, "Checking DH parameters failed"_s);
        return 0;
    }

    return static_cast<int32_t>(result);
}

} // namespace Bun
