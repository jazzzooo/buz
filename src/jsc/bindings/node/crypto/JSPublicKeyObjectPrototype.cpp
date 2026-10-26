#include "JSPublicKeyObjectPrototype.h"
#include "JSPublicKeyObject.h"
#include "SchemaBindings.h"
#include "ErrorCode.h"
#include "CryptoUtil.h"
#include "CryptoKeys.h"
#include "BunProcess.h"
#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>

using namespace Bun;
using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

static JSPublicKeyObject* publicKeyObject(JSC::JSValue value)
{
    auto* key = dynamicDowncast<JSPublicKeyObject>(value);
    RELEASE_ASSERT(key);
    return key;
}

static JSPublicKeyObject* publicKeyObject(const std::optional<JSC::JSValue>& value)
{
    return value ? publicKeyObject(*value) : nullptr;
}

const JSC::ClassInfo JSPublicKeyObjectPrototype::s_info = { "PublicKeyObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSPublicKeyObjectPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSPublicKeyObjectPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSPublicKeyObjectPrototype

void JSPublicKeyObjectPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);

    bunBindgenObjectSurface_JSPublicKeyObjectPrototype_install(vm, JSPublicKeyObjectPrototype::info(), *this);

    // Inherit KeyObject's toStringTag.
}

Bindgen::NodeCryptoPublicKeyExportResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_publicKeyObjectExport(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_publicKeyObjectExport_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    auto* key = publicKeyObject(args.bindingThis);
    ncrypto::EVPKeyPointer::PublicKeyEncodingConfig config {};
    bool parsed = parseNodeCryptoPublicKeyExportOptions(*globalObject, args.options, key->handle(), config);
    RETURN_IF_EXCEPTION(scope, {});
    if (!parsed)
        return {};
    return key->handle().exportPublicResult(globalObject, scope, config);
}

std::optional<Bindgen::NodeCryptoAsymmetricKeyKind> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_publicKeyObjectAsymmetricKeyType(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_publicKeyObjectAsymmetricKeyType_Arguments& args)
{
    JSPublicKeyObject* key = publicKeyObject(args.bindingThis);
    if (!key)
        return std::nullopt;

    return key->handle().asymmetricKeyType();
}

std::optional<Bindgen::NodeCryptoAsymmetricKeyDetailsResult> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_publicKeyObjectAsymmetricKeyDetails(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_publicKeyObjectAsymmetricKeyDetails_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    JSPublicKeyObject* key = publicKeyObject(args.bindingThis);
    if (!key)
        return std::nullopt;

    auto result = nodeCryptoAsymmetricKeyDetails(*globalObject, scope, key->handle());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return result;
}
