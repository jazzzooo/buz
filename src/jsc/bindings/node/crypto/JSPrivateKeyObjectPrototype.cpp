#include "JSPrivateKeyObjectPrototype.h"
#include "JSPrivateKeyObject.h"
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

static JSPrivateKeyObject* privateKeyObject(JSC::JSValue value)
{
    auto* key = dynamicDowncast<JSPrivateKeyObject>(value);
    RELEASE_ASSERT(key);
    return key;
}

static JSPrivateKeyObject* privateKeyObject(const std::optional<JSC::JSValue>& value)
{
    return value ? privateKeyObject(*value) : nullptr;
}

const JSC::ClassInfo JSPrivateKeyObjectPrototype::s_info = { "PrivateKeyObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSPrivateKeyObjectPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSPrivateKeyObjectPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSPrivateKeyObjectPrototype

void JSPrivateKeyObjectPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);

    bunBindgenObjectSurface_JSPrivateKeyObjectPrototype_install(vm, JSPrivateKeyObjectPrototype::info(), *this);

    // Inherit KeyObject's toStringTag.
}

Bindgen::NodeCryptoPrivateKeyExportResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_privateKeyObjectExport(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_privateKeyObjectExport_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    auto* key = privateKeyObject(args.bindingThis);
    ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig config {};
    bool parsed = parseNodeCryptoPrivateKeyExportOptions(*globalObject, args.options, key->handle(), config);
    RETURN_IF_EXCEPTION(scope, {});
    if (!parsed)
        return {};
    return key->handle().exportPrivateResult(globalObject, scope, config);
}

std::optional<Bindgen::NodeCryptoAsymmetricKeyKind> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_privateKeyObjectAsymmetricKeyType(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_privateKeyObjectAsymmetricKeyType_Arguments& args)
{
    JSPrivateKeyObject* key = privateKeyObject(args.bindingThis);
    if (!key)
        return std::nullopt;

    return key->handle().asymmetricKeyType();
}

std::optional<Bindgen::NodeCryptoAsymmetricKeyDetailsResult> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_privateKeyObjectAsymmetricKeyDetails(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_privateKeyObjectAsymmetricKeyDetails_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    JSPrivateKeyObject* key = privateKeyObject(args.bindingThis);
    if (!key)
        return std::nullopt;

    auto result = nodeCryptoAsymmetricKeyDetails(*globalObject, scope, key->handle());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return result;
}
