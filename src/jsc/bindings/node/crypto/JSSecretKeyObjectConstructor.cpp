#include "JSSecretKeyObjectConstructor.h"
#include "JSSecretKeyObject.h"
#include "ErrorCode.h"
#include "JSBufferEncodingType.h"
#include "NodeValidator.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include "CryptoUtil.h"
#include "openssl/dh.h"
#include "openssl/bn.h"
#include "openssl/err.h"
#include "ncrypto.h"

using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

namespace Bun {

const JSC::ClassInfo JSSecretKeyObjectConstructor::s_info = { "SecretKeyObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSSecretKeyObjectConstructor) };

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_secretKeyObjectConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_secretKeyObjectConstructorCall_Arguments&)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    throwConstructorCannotBeCalledAsFunctionTypeError(lexicalGlobalObject, scope, "SecretKeyObject"_s);
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_secretKeyObjectConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_secretKeyObjectConstructorConstruct_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    JSC::VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    JSValue handleValue = args.handle.value_or(JSC::jsUndefined());
    ERR::INVALID_ARG_TYPE(scope, lexicalGlobalObject, "handle"_s, "object"_s, handleValue);
}

} // namespace Bun
