#include "JSDiffieHellmanGroupConstructor.h"
#include "JSDiffieHellmanGroup.h"
#include <JavaScriptCore/LazyClassStructureInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include "ErrorCode.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include "ZigGlobalObject.h"

namespace Bun {

const JSC::ClassInfo JSDiffieHellmanGroupConstructor::s_info = { "Function"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSDiffieHellmanGroupConstructor) };

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupConstructorCall_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    JSC::VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto* constructor = globalObject->m_JSDiffieHellmanGroupClassStructure.constructor(globalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSC::MarkedArgumentBuffer forwardedArguments;
    if (args.name) {
        args.name->appendTo(forwardedArguments);
    }
    auto callData = JSC::getConstructData(constructor);
    JSC::JSValue result = JSC::construct(globalObject, constructor, callData, ArgList(forwardedArguments));
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupConstructorConstruct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    JSC::VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto dh = ncrypto::DHPointer::FromGroup(args.name);
    if (!dh) {
        return JSC::JSValue::decode(Bun::ERR::CRYPTO_UNKNOWN_DH_GROUP(scope, globalObject));
    }

    // Get the appropriate structure and create the DiffieHellmanGroup object
    auto* zigGlobalObject = dynamicDowncast<Zig::GlobalObject>(globalObject);
    JSC::Structure* structure = zigGlobalObject->m_JSDiffieHellmanGroupClassStructure.get(zigGlobalObject);
    auto* newTarget = JSC::asObject(args.bindingNewTarget);

    if (zigGlobalObject->m_JSDiffieHellmanGroupClassStructure.constructor(zigGlobalObject) != newTarget) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* functionGlobalObject = defaultGlobalObject(JSC::getFunctionRealm(globalObject, newTarget));
        RETURN_IF_EXCEPTION(scope, {});
        structure = JSC::InternalFunction::createSubclassStructure(globalObject, newTarget, functionGlobalObject->m_JSDiffieHellmanGroupClassStructure.get(functionGlobalObject));
        RETURN_IF_EXCEPTION(scope, {});
    }

    return JSDiffieHellmanGroup::create(vm, structure, globalObject, WTF::move(dh));
}

} // namespace Bun
