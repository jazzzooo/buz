#include "JSDiffieHellmanGroupPrototype.h"
#include "JSDiffieHellmanGroup.h"
#include "SchemaBindings.h"
#include "DiffieHellmanFunctions.h"
#include "ErrorCode.h"

#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>

namespace Bun {

static JSDiffieHellmanGroup* diffieHellmanGroupReceiver(JSC::JSValue value)
{
    auto* result = dynamicDowncast<JSDiffieHellmanGroup>(value);
    RELEASE_ASSERT(result);
    return result;
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGenerateKeys(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGenerateKeys_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGenerateKeysTemplate<JSDiffieHellmanGroup>(&context.globalObject, diffieHellmanGroupReceiver(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupComputeSecret(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupComputeSecret_Arguments& args)
{
    return jsDiffieHellmanProtoFuncComputeSecretTemplate<JSDiffieHellmanGroup>(context, &context.globalObject, diffieHellmanGroupReceiver(args.bindingThis), args.key, args.inputEncoding, args.outputEncoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetPrime(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetPrime_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetPrimeTemplate<JSDiffieHellmanGroup>(&context.globalObject, diffieHellmanGroupReceiver(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetGenerator(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetGenerator_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetGeneratorTemplate<JSDiffieHellmanGroup>(&context.globalObject, diffieHellmanGroupReceiver(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetPublicKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetPublicKey_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetPublicKeyTemplate<JSDiffieHellmanGroup>(&context.globalObject, diffieHellmanGroupReceiver(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetPrivateKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupGetPrivateKey_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetPrivateKeyTemplate<JSDiffieHellmanGroup>(&context.globalObject, diffieHellmanGroupReceiver(args.bindingThis), args.encoding);
}

const JSC::ClassInfo JSDiffieHellmanGroupPrototype::s_info = { "DiffieHellmanGroup"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSDiffieHellmanGroupPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanGroupPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanGroupPrototype

void JSDiffieHellmanGroupPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSDiffieHellmanGroupPrototype_install(vm, JSDiffieHellmanGroup::info(), *this);
}

} // namespace Bun
