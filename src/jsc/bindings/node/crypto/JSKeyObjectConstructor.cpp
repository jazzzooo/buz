#include "JSKeyObjectConstructor.h"
#include "JSDOMExceptionHandling.h"
#include "JSKeyObject.h"
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
#include "WebCryptoKey.h"
#include "JSSecretKeyObject.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"
#include "ZigGlobalObject.h"
#include "CryptoKeyAES.h"
#include "CryptoKeyHMAC.h"
#include "CryptoKeyRaw.h"
#include "CryptoKey.h"
#include "CryptoKeyType.h"
using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

namespace Bun {


#define BUN_BINDGEN_OBJECT_SURFACE_JSKeyObjectConstructor
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSKeyObjectConstructor

const JSC::ClassInfo JSKeyObjectConstructor::s_info = { "KeyObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSKeyObjectConstructor) };

void JSKeyObjectConstructor::finishCreation(VM& vm, JSGlobalObject* globalObject, JSObject* prototype)
{
    Base::finishCreation(vm, 2, "KeyObject"_s);
    putDirect(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly);
    bunBindgenObjectSurface_JSKeyObjectConstructor_install(vm, JSKeyObjectConstructor::info(), *this);
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_keyObjectConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_keyObjectConstructorCall_Arguments&)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    throwTypeError(lexicalGlobalObject, scope, "Cannot call KeyObject class constructor without |new|"_s);
}

void Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_keyObjectConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_keyObjectConstructorConstruct_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    JSC::VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    (void)args.type;

    JSValue handleValue = args.handle.value_or(JSC::jsUndefined());
    ERR::INVALID_ARG_TYPE(scope, lexicalGlobalObject, "handle"_s, "object"_s, handleValue);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_keyObjectFrom(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_keyObjectFrom_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    WebCore::CryptoKey& wrappedKey = webCryptoKey(args.key);

    auto keyObjectResult = KeyObject::create(wrappedKey);
    if (keyObjectResult.hasException()) [[unlikely]] {
        WebCore::propagateException(*lexicalGlobalObject, scope, keyObjectResult.releaseException());
        RELEASE_AND_RETURN(scope, {});
        return {};
    }

    // 2. Determine Key Type and Extract Material
    switch (wrappedKey.type()) {
    case CryptoKeyType::Secret: {
        auto* structure = globalObject->m_JSSecretKeyObjectClassStructure.get(globalObject);
        JSSecretKeyObject* instance = JSSecretKeyObject::create(vm, structure, globalObject, keyObjectResult.releaseReturnValue());
        RELEASE_AND_RETURN(scope, instance);
    }

    case CryptoKeyType::Public: {
        auto* structure = globalObject->m_JSPublicKeyObjectClassStructure.get(globalObject);
        JSPublicKeyObject* instance = JSPublicKeyObject::create(vm, structure, globalObject, keyObjectResult.releaseReturnValue());
        RELEASE_AND_RETURN(scope, instance);
    }

    case CryptoKeyType::Private: {
        auto* structure = globalObject->m_JSPrivateKeyObjectClassStructure.get(globalObject);
        JSPrivateKeyObject* instance = JSPrivateKeyObject::create(vm, structure, globalObject, keyObjectResult.releaseReturnValue());
        RELEASE_AND_RETURN(scope, instance);
    }
    }

    ASSERT_NOT_REACHED();

    // Should not be reached
    RELEASE_AND_RETURN(scope, jsUndefined());
}

} // namespace Bun
