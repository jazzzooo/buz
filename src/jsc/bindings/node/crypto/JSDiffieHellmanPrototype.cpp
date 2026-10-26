#include "JSDiffieHellmanPrototype.h"
#include "JSDiffieHellman.h"
#include "SchemaBindings.h"
#include "DiffieHellmanFunctions.h"
#include "ErrorCode.h"

#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>

namespace Bun {

static JSDiffieHellman* diffieHellman(JSC::JSValue value)
{
    auto* result = dynamicDowncast<JSDiffieHellman>(value);
    RELEASE_ASSERT(result);
    return result;
}

const JSC::ClassInfo JSDiffieHellmanPrototype::s_info = { "DiffieHellman"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSDiffieHellmanPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSDiffieHellmanPrototype

void JSDiffieHellmanPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSDiffieHellmanPrototype_install(vm, JSDiffieHellmanPrototype::info(), *this);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGenerateKeys(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGenerateKeys_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGenerateKeysTemplate<JSDiffieHellman>(&context.globalObject, diffieHellman(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanComputeSecret(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanComputeSecret_Arguments& args)
{
    return jsDiffieHellmanProtoFuncComputeSecretTemplate<JSDiffieHellman>(context, &context.globalObject, diffieHellman(args.bindingThis), args.key, args.inputEncoding, args.outputEncoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGetPrime(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGetPrime_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetPrimeTemplate<JSDiffieHellman>(&context.globalObject, diffieHellman(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGetGenerator(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGetGenerator_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetGeneratorTemplate<JSDiffieHellman>(&context.globalObject, diffieHellman(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGetPublicKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGetPublicKey_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetPublicKeyTemplate<JSDiffieHellman>(&context.globalObject, diffieHellman(args.bindingThis), args.encoding);
}

Bindgen::NodeCryptoEncodedOutputResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGetPrivateKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGetPrivateKey_Arguments& args)
{
    return jsDiffieHellmanProtoFuncGetPrivateKeyTemplate<JSDiffieHellman>(&context.globalObject, diffieHellman(args.bindingThis), args.encoding);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanSetPublicKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanSetPublicKey_Arguments& args)
{
    return JSC::JSValue::decode(jsDiffieHellmanProtoFuncSetPublicKeyTemplate<JSDiffieHellman>(context, &context.globalObject, diffieHellman(args.bindingThis), args.key, args.encoding));
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanSetPrivateKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanSetPrivateKey_Arguments& args)
{
    return JSC::JSValue::decode(jsDiffieHellmanProtoFuncSetPrivateKeyTemplate<JSDiffieHellman>(context, &context.globalObject, diffieHellman(args.bindingThis), args.key, args.encoding));
}

} // namespace Bun
