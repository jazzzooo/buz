#include "JSSecretKeyObjectPrototype.h"
#include "JSSecretKeyObject.h"
#include "SchemaBindings.h"
#include "ErrorCode.h"
#include "CryptoUtil.h"
#include "BunProcess.h"
#include "NodeValidator.h"
#include "JSBufferEncodingType.h"
#include "JSBuffer.h"
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/JSCJSValueInlines.h>

using namespace Bun;
using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

static JSSecretKeyObject* secretKeyObject(JSC::JSValue value)
{
    auto* key = dynamicDowncast<JSSecretKeyObject>(value);
    RELEASE_ASSERT(key);
    return key;
}

static JSSecretKeyObject* secretKeyObject(const std::optional<JSC::JSValue>& value)
{
    return value ? secretKeyObject(*value) : nullptr;
}

const JSC::ClassInfo JSSecretKeyObjectPrototype::s_info = { "SecretKeyObject"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSSecretKeyObjectPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSSecretKeyObjectPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSSecretKeyObjectPrototype

void JSSecretKeyObjectPrototype::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSSecretKeyObjectPrototype_install(vm, JSSecretKeyObjectPrototype::info(), *this);

    // Inherit KeyObject's toStringTag.
}

Bindgen::NodeCryptoSecretKeyExportResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_secretKeyObjectExport(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_secretKeyObjectExport_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);

    const bool jwk = args.options && args.options->format &&
        *args.options->format == Bun::Bindgen::NodeCryptoSecretKeyExportFormat::jwk;
    auto key = secretKeyObject(args.bindingThis)->handle().symmetricKey().span();
    Bindgen::NodeCryptoSecretKeyExportResult result;
    if (jwk) {
        auto encoded = bufferToStringFromBytes(globalObject, scope, key, BufferEncodingType::base64url);
        RETURN_IF_EXCEPTION(scope, {});
        Bindgen::NodeCryptoSecretJwkResult value {
            .kty = "oct"_s,
            .k = WTF::move(encoded),
        };
        result.set_jwk(WTF::move(value));
        return result;
    }

    WTF::Vector<uint8_t> bytes;
    if (!bytes.tryGrow(key.size())) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    if (!key.empty())
        memcpy(bytes.mutableSpan().data(), key.data(), key.size());
    result.set_buffer(WTF::move(bytes));
    return result;
}

std::optional<double> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_secretKeyObjectSymmetricKeySize(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_secretKeyObjectSymmetricKeySize_Arguments& args)
{
    JSSecretKeyObject* key = secretKeyObject(args.bindingThis);
    if (!key)
        return std::nullopt;

    return static_cast<double>(key->handle().symmetricKey().size());
}
