#include "JSKeyObjectPrototype.h"
#include "JSKeyObject.h"
#include "ErrorCode.h"
#include "CryptoUtil.h"
#include "BunProcess.h"
#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>

using namespace Bun;
using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

const JSC::ClassInfo JSKeyObjectPrototype::s_info = { "KeyObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSKeyObjectPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSKeyObjectPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSKeyObjectPrototype

void JSKeyObjectPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSKeyObjectPrototype_install(vm, JSKeyObjectPrototype::info(), *this);
}

bool Bun::Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_keyObjectEquals(
    Bun::Bindgen::CppCallContext& context,
    const Bun::Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_keyObjectEquals_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    KeyObject& thisHandle = JSKeyObject::from(args.bindingThis)->handle();

    std::optional<bool> result = thisHandle.equals(JSKeyObject::from(args.otherKeyObject)->handle());
    if (!result.has_value()) {
        ERR::CRYPTO_UNSUPPORTED_OPERATION(scope, globalObject);
        return false;
    }

    return *result;
}

std::optional<WTF::String> Bun::Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_keyObjectType(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_keyObjectType_Arguments& args)
{
    JSKeyObject* key = JSKeyObject::from(args.bindingThis);
    if (!key)
        return std::nullopt;

    switch (key->handle().type()) {
    case CryptoKeyType::Secret:
        return WTF::String("secret"_s);
    case CryptoKeyType::Public:
        return WTF::String("public"_s);
    case CryptoKeyType::Private:
        return WTF::String("private"_s);
    }

    RELEASE_ASSERT_NOT_REACHED();
}
