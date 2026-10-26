#include "JSCipher.h"
#include "SchemaBindings.h"
#include "JSCipherPrototype.h"
#include "JSCipherConstructor.h"
#include "DOMIsoSubspaces.h"
#include "ZigGlobalObject.h"
#include "ErrorCode.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include <JavaScriptCore/LazyClassStructureInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/ObjectPrototype.h>
#include "CryptoUtil.h"
#include "openssl/rsa.h"
#include "KeyObject.h"

namespace Bun {

const JSC::ClassInfo JSCipher::s_info = { "Cipher"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSCipher) };

void JSCipher::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
{
    Base::finishCreation(vm);
}

template<typename Visitor>
void JSCipher::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    JSCipher* thisObject = uncheckedDowncast<JSCipher>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(JSCipher);

void setupCipherClassStructure(JSC::LazyClassStructure::Initializer& init)
{
    auto* prototypeStructure = JSCipherPrototype::createStructure(init.vm, init.global, init.global->objectPrototype());
    auto* prototype = JSCipherPrototype::create(init.vm, init.global, prototypeStructure);

    auto* constructorStructure = JSCipherConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());
    auto* constructor = JSCipherConstructor::create(init.vm, constructorStructure, prototype);

    auto* structure = JSCipher::createStructure(init.vm, init.global, prototype);
    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

enum class CipherOperation {
    encrypt,
    decrypt,
    sign,
    recover,
};

struct NodeCryptoRsaKey {
    RefPtr<KeyObjectData> keyData;
    std::optional<int32_t> padding;
    ncrypto::Digest digest;
    WebCore::BufferEncodingType encoding;
    WTF::Vector<uint8_t> oaepLabel;
};

static std::optional<NodeCryptoRsaKey> rsaKeyFromInput(JSC::JSGlobalObject& global, const Bindgen::NodeCryptoAsymmetricKeyInput& input, bool privateKey)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    ncrypto::MarkPopErrorOnReturn popErrorScope;
    auto keyData = KeyObject::prepareAsymmetricKey(
        &global,
        scope,
        input,
        privateKey ? KeyObject::PrepareAsymmetricKeyMode::ConsumePrivate : KeyObject::PrepareAsymmetricKeyMode::ConsumePublic);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!keyData)
        return std::nullopt;

    std::optional<int32_t> padding;
    ncrypto::Digest digest;
    BufferEncodingType encoding = BufferEncodingType::utf8;
    WTF::Vector<uint8_t> oaepLabel;
    if (input.is_options()) {
        const auto& options = input.options();
        const auto* convertedPadding = options.padding.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        const auto* convertedHash = options.oaep_hash.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!convertedPadding || !convertedHash)
            return std::nullopt;

        padding = *convertedPadding;
        if (convertedHash->has_value()) {
            digest = ncrypto::Digest::FromName(WTF::StringView { **convertedHash });
            if (!digest) {
                ERR::OSSL_EVP_INVALID_DIGEST(scope, &global);
                return std::nullopt;
            }
        }
        const auto* convertedEncoding = options.encoding.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!convertedEncoding)
            return std::nullopt;
        if (convertedEncoding->has_value())
            encoding = nodeEncodingToBufferEncoding(**convertedEncoding);

        const auto* convertedLabel = options.oaep_label.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!convertedLabel)
            return std::nullopt;
        if (convertedLabel->has_value()) {
            const auto& label = **convertedLabel;
            bool copied;
            if (label.is_buffer()) {
                copied = oaepLabel.tryAppend(label.buffer());
            } else {
                RELEASE_ASSERT(label.is_string());
                auto* encoded = encodeCryptoString(&global, scope, label.string(), encoding);
                RETURN_IF_EXCEPTION(scope, std::nullopt);
                copied = oaepLabel.tryAppend(encoded->span());
                JSC::ensureStillAliveHere(encoded);
            }
            if (!copied) {
                JSC::throwOutOfMemoryError(&global, scope);
                return std::nullopt;
            }
        }
    }

    scope.release();
    return NodeCryptoRsaKey { WTF::move(keyData), padding, digest, encoding, WTF::move(oaepLabel) };
}

template<typename Buffer>
WTF::Vector<uint8_t> rsaFunction(Bindgen::CppCallContext& context, JSC::JSGlobalObject* lexicalGlobalObject, const Bindgen::NodeCryptoAsymmetricKeyInput& keyInput, const Bindgen::CppLazyArgument<Buffer>& bufferArgument, CipherOperation operation, int32_t defaultPadding, bool privateKey)
{
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    auto key = rsaKeyFromInput(*globalObject, keyInput, privateKey);
    RETURN_IF_EXCEPTION(scope, {});
    if (!key)
        return {};
    KeyObject::discardAsymmetricKeyDeferred(keyInput);
    auto& pkey = key->keyData->asymmetricKey;
    int32_t padding = key->padding.value_or(defaultPadding);

    const auto* convertedBuffer = Bindgen::convertLastAndLease(context, bufferArgument);
    RETURN_IF_EXCEPTION(scope, {});
    if (!convertedBuffer)
        return {};
    auto buffer = getStringOrBufferBytes(lexicalGlobalObject, scope, *convertedBuffer, key->encoding);
    RETURN_IF_EXCEPTION(scope, {});

    if (operation == CipherOperation::decrypt && padding == RSA_PKCS1_PADDING) {
        ncrypto::EVPKeyCtxPointer ctx = pkey.newCtx();

        if (!ctx.initForDecrypt()) {
            throwCryptoError(lexicalGlobalObject, scope, ERR_get_error());
            return {};
        }

        throwError(lexicalGlobalObject, scope, ErrorCode::ERR_INVALID_ARG_VALUE, "RSA_PKCS1_PADDING is no longer supported for private decryption"_s);
        return {};
    }

    ncrypto::Buffer<const void> labelBuf = {};
    if (!key->oaepLabel.isEmpty()) {
        labelBuf = {
            .data = key->oaepLabel.begin(),
            .len = key->oaepLabel.size(),
        };
    }

    ncrypto::Cipher::CipherParams cipherParams {
        .padding = padding,
        .digest = key->digest,
        .label = labelBuf,
    };

    ncrypto::Buffer<const void> bufferBuf {
        .data = buffer->data(),
        .len = buffer->size(),
    };

    ncrypto::DataPointer result;
    switch (operation) {
    case CipherOperation::encrypt:
        result = ncrypto::Cipher::encrypt(pkey, cipherParams, bufferBuf);
        break;
    case CipherOperation::decrypt:
        result = ncrypto::Cipher::decrypt(pkey, cipherParams, bufferBuf);
        break;
    case CipherOperation::sign:
        result = ncrypto::Cipher::sign(pkey, cipherParams, bufferBuf);
        break;
    case CipherOperation::recover:
        result = ncrypto::Cipher::recover(pkey, cipherParams, bufferBuf);
        break;
    }

    if (!result) {
        throwCryptoError(lexicalGlobalObject, scope, ERR_get_error());
        return {};
    }

    WTF::Vector<uint8_t> output;
    if (!output.tryGrow(result.size())) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    if (!result.span().empty())
        memcpy(output.mutableSpan().data(), result.span().data(), result.size());

    return output;
}

Bun::Bindgen::CppBytes Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_publicEncrypt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_publicEncrypt_Arguments& args)
{
    return rsaFunction(context, &context.globalObject, args.options, args.buffer, CipherOperation::encrypt, RSA_PKCS1_OAEP_PADDING, false);
}
Bun::Bindgen::CppBytes Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_publicDecrypt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_publicDecrypt_Arguments& args)
{
    return rsaFunction(context, &context.globalObject, args.options, args.buffer, CipherOperation::recover, RSA_PKCS1_PADDING, false);
}
Bun::Bindgen::CppBytes Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_privateEncrypt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_privateEncrypt_Arguments& args)
{
    return rsaFunction(context, &context.globalObject, args.options, args.buffer, CipherOperation::sign, RSA_PKCS1_PADDING, true);
}
Bun::Bindgen::CppBytes Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_privateDecrypt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_privateDecrypt_Arguments& args)
{
    return rsaFunction(context, &context.globalObject, args.options, args.buffer, CipherOperation::decrypt, RSA_PKCS1_OAEP_PADDING, true);
}

} // namespace Bun
