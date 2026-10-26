#include "JSDiffieHellman.h"
#include "JSDiffieHellmanPrototype.h"
#include "JSDiffieHellmanConstructor.h"
#include "DOMIsoSubspaces.h"
#include "ZigGlobalObject.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <JavaScriptCore/LazyClassStructureInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/ObjectPrototype.h>
#include "JSDOMExceptionHandling.h"

namespace Bun {

const JSC::ClassInfo JSDiffieHellman::s_info = { "DiffieHellman"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSDiffieHellman) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanInstance
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanInstance

void JSDiffieHellman::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSDiffieHellmanInstance_install(vm, info(), *this);

    m_sizeForGC = this->m_dh.size();
    vm.heap.reportExtraMemoryAllocated(this, m_sizeForGC);
}

template<typename Visitor>
void JSDiffieHellman::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSDiffieHellman* thisObject = uncheckedDowncast<JSDiffieHellman>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);

    visitor.reportExtraMemoryVisited(thisObject->m_sizeForGC);
}

DEFINE_VISIT_CHILDREN(JSDiffieHellman);

void setupDiffieHellmanClassStructure(JSC::LazyClassStructure::Initializer& init)
{
    auto* prototypeStructure = JSDiffieHellmanPrototype::createStructure(init.vm, init.global, init.global->objectPrototype());
    auto* prototype = JSDiffieHellmanPrototype::create(init.vm, init.global, prototypeStructure);

    auto* constructorStructure = JSDiffieHellmanConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());
    auto* constructor = JSDiffieHellmanConstructor::create(init.vm, constructorStructure, prototype);

    auto* structure = JSDiffieHellman::createStructure(init.vm, init.global, prototype);
    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

int32_t Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanVerifyError(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanVerifyError_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* receiver = dynamicDowncast<JSDiffieHellman>(args.bindingThis);
    RELEASE_ASSERT(receiver);
    auto& dh = receiver->getImpl();
    auto result = dh.check();
    if (result == ncrypto::DHPointer::CheckResult::CHECK_FAILED) {
        Bun::ERR::CRYPTO_OPERATION_FAILED(scope, globalObject, "Checking DH parameters failed"_s);
        return 0;
    }

    return static_cast<int32_t>(result);
}

} // namespace Bun
