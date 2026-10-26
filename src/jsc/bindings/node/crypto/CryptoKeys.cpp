#include "SchemaBindings.h"
#include "CryptoKeys.h"
#include "NodeValidator.h"
#include "ErrorCode.h"
#include "CryptoUtil.h"
#include "JSDOMExceptionHandling.h"
#include "JSSecretKeyObject.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"

using namespace JSC;

namespace Bun {

namespace {

KeyObject* createAsymmetricKey(JSGlobalObject& globalObject, const Bindgen::NodeCryptoAsymmetricKeyInput& input, KeyObject::PrepareAsymmetricKeyMode mode, CryptoKeyType type)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    auto keyData = KeyObject::prepareAsymmetricKey(&globalObject, scope, input, mode);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!keyData)
        return nullptr;

    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(KeyObject)).getValue(storage)) {
        throwOutOfMemoryError(&globalObject, scope);
        return nullptr;
    }
    auto* result = new (NotNull, storage) KeyObject(KeyObject::create(type, WTF::move(keyData)));
    scope.release();
    return result;
}

ncrypto::EVPKeyPointer::PKFormatType toNcryptoKeyExportFormat(Bindgen::NodeCryptoKeyExportFormat format)
{
    switch (format) {
    case Bindgen::NodeCryptoKeyExportFormat::pem:
        return ncrypto::EVPKeyPointer::PKFormatType::PEM;
    case Bindgen::NodeCryptoKeyExportFormat::der:
        return ncrypto::EVPKeyPointer::PKFormatType::DER;
    case Bindgen::NodeCryptoKeyExportFormat::jwk:
        return ncrypto::EVPKeyPointer::PKFormatType::JWK;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

ncrypto::EVPKeyPointer::PKEncodingType toNcryptoPublicKeyExportType(Bindgen::NodeCryptoPublicKeyExportType type)
{
    switch (type) {
    case Bindgen::NodeCryptoPublicKeyExportType::pkcs1:
        return ncrypto::EVPKeyPointer::PKEncodingType::PKCS1;
    case Bindgen::NodeCryptoPublicKeyExportType::spki:
        return ncrypto::EVPKeyPointer::PKEncodingType::SPKI;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

ncrypto::EVPKeyPointer::PKEncodingType toNcryptoPrivateKeyExportType(Bindgen::NodeCryptoPrivateKeyExportType type)
{
    switch (type) {
    case Bindgen::NodeCryptoPrivateKeyExportType::pkcs1:
        return ncrypto::EVPKeyPointer::PKEncodingType::PKCS1;
    case Bindgen::NodeCryptoPrivateKeyExportType::pkcs8:
        return ncrypto::EVPKeyPointer::PKEncodingType::PKCS8;
    case Bindgen::NodeCryptoPrivateKeyExportType::sec1:
        return ncrypto::EVPKeyPointer::PKEncodingType::SEC1;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

}

bool parseNodeCryptoPublicKeyExportOptions(
    JSGlobalObject& globalObject,
    const Bindgen::NodeCryptoPublicKeyExportOptions& options,
    const KeyObject& receiver,
    ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    config.format = toNcryptoKeyExportFormat(options.format);
    if (options.format == Bindgen::NodeCryptoKeyExportFormat::jwk) {
        scope.release();
        return true;
    }

    const auto* type = options.type.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!type)
        return false;
    if (*type == Bindgen::NodeCryptoPublicKeyExportType::pkcs1 && receiver.asymmetricKeyType() != Bindgen::NodeCryptoAsymmetricKeyKind::rsa) {
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, &globalObject, "pkcs1"_s, "can only be used for RSA keys"_s);
        return false;
    }
    config.type = toNcryptoPublicKeyExportType(*type);
    scope.release();
    return true;
}

bool parseNodeCryptoPrivateKeyExportOptions(
    JSGlobalObject& globalObject,
    const Bindgen::NodeCryptoPrivateKeyExportOptions& options,
    const KeyObject& receiver,
    ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject.vm());
    config.format = toNcryptoKeyExportFormat(options.format);
    if (options.format == Bindgen::NodeCryptoKeyExportFormat::jwk) {
        const auto* passphrasePresent = options.passphrase_present.convert();
        RETURN_IF_EXCEPTION(scope, false);
        if (!passphrasePresent)
            return false;
        if (passphrasePresent->has_value()) {
            ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, &globalObject, "jwk"_s, "does not support encryption"_s);
            return false;
        }
        scope.release();
        return true;
    }

    const auto* type = options.type.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!type)
        return false;
    if (*type == Bindgen::NodeCryptoPrivateKeyExportType::pkcs1 && receiver.asymmetricKeyType() != Bindgen::NodeCryptoAsymmetricKeyKind::rsa) {
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, &globalObject, "pkcs1"_s, "can only be used for RSA keys"_s);
        return false;
    }
    if (*type == Bindgen::NodeCryptoPrivateKeyExportType::sec1 && receiver.asymmetricKeyType() != Bindgen::NodeCryptoAsymmetricKeyKind::ec) {
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, &globalObject, "sec1"_s, "can only be used for EC keys"_s);
        return false;
    }
    config.type = toNcryptoPrivateKeyExportType(*type);

    const auto* cipher = options.cipher.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!cipher)
        return false;
    if (cipher->has_value() && options.format == Bindgen::NodeCryptoKeyExportFormat::der &&
        (*type == Bindgen::NodeCryptoPrivateKeyExportType::pkcs1 || *type == Bindgen::NodeCryptoPrivateKeyExportType::sec1)) {
        auto typeName = *type == Bindgen::NodeCryptoPrivateKeyExportType::pkcs1 ? "pkcs1"_s : "sec1"_s;
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, &globalObject, typeName, "does not support encryption"_s);
        return false;
    }

    const auto* passphrase = options.passphrase.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!passphrase)
        return false;
    if (!cipher->has_value() && passphrase->has_value()) {
        ERR::INVALID_ARG_VALUE(scope, &globalObject, "options.cipher"_s, jsUndefined());
        return false;
    }

    if (passphrase->has_value()) {
        const auto* encoding = options.encoding.convert();
        RETURN_IF_EXCEPTION(scope, false);
        if (!encoding)
            return false;
        auto bytes = getStringOrBufferBytes(
            &globalObject,
            scope,
            passphrase->value(),
            nodeEncodingOrDefault(*encoding, BufferEncodingType::utf8));
        RETURN_IF_EXCEPTION(scope, false);
        auto copied = ncrypto::DataPointer::FromSpan(std::span<const uint8_t> { bytes->data(), bytes->size() });
        if (!bytes->empty() && !copied) {
            throwOutOfMemoryError(&globalObject, scope);
            return false;
        }
        config.passphrase = WTF::move(copied);
    }

    if (cipher->has_value()) {
        auto* resolvedCipher = ncrypto::getCipherByName(WTF::StringView(cipher->value()));
        if (!resolvedCipher) {
            ERR::CRYPTO_UNKNOWN_CIPHER(scope, &globalObject, cipher->value());
            return false;
        }
        config.cipher = resolvedCipher;
    }

    scope.release();
    return true;
}

Bindgen::NodeCryptoAsymmetricKeyDetailsResult nodeCryptoAsymmetricKeyDetails(
    JSGlobalObject& globalObject,
    ThrowScope& scope,
    KeyObject& key)
{
    auto details = key.asymmetricKeyDetails(&globalObject, scope);
    RETURN_IF_EXCEPTION(scope, {});

    Bindgen::NodeCryptoAsymmetricKeyDetailsResult result {
        .modulus_length = details.modulus_length,
        .hash_algorithm = WTF::move(details.hash_algorithm),
        .mgf1_hash_algorithm = WTF::move(details.mgf1_hash_algorithm),
        .salt_length = details.salt_length,
        .divisor_length = details.divisor_length,
        .named_curve = WTF::move(details.named_curve),
    };
    if (details.public_exponent_hex) {
        auto publicExponent = JSBigInt::parseInt(
            &globalObject,
            globalObject.vm(),
            *details.public_exponent_hex,
            16,
            JSBigInt::ErrorParseMode::IgnoreExceptions,
            JSBigInt::ParseIntSign::Unsigned);
        if (!publicExponent) {
            ERR::CRYPTO_OPERATION_FAILED(scope, &globalObject, "Failed to create public exponent"_s);
            return {};
        }
        result.public_exponent = publicExponent;
    }
    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_createSecretKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_createSecretKey_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    auto keyData = getStringOrBufferBytes(
        lexicalGlobalObject,
        scope,
        args.key,
        nodeEncodingOrDefault(args.encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, {});

    WTF::Vector<uint8_t> keyBytes;
    if (!keyBytes.tryAppend(std::span<const uint8_t> { keyData->data(), keyData->size() })) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    KeyObject keyObject = KeyObject::create(lexicalGlobalObject, scope, WTF::move(keyBytes));
    RETURN_IF_EXCEPTION(scope, {});

    Structure* structure = globalObject->m_JSSecretKeyObjectClassStructure.get(lexicalGlobalObject);
    JSSecretKeyObject* secretKey = JSSecretKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));

    return secretKey;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_createPublicKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_createPublicKey_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    std::unique_ptr<KeyObject> prepared(createAsymmetricKey(
        *lexicalGlobalObject,
        args.key,
        KeyObject::PrepareAsymmetricKeyMode::CreatePublic,
        CryptoKeyType::Public));
    RETURN_IF_EXCEPTION(scope, {});
    if (!prepared)
        return {};
    KeyObject keyObject = WTF::move(*prepared);

    Structure* structure = globalObject->m_JSPublicKeyObjectClassStructure.get(lexicalGlobalObject);
    JSPublicKeyObject* publicKey = JSPublicKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));

    return publicKey;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_createPrivateKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_createPrivateKey_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    ThrowScope scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);

    std::unique_ptr<KeyObject> prepared(createAsymmetricKey(
        *lexicalGlobalObject,
        args.key,
        KeyObject::PrepareAsymmetricKeyMode::CreatePrivate,
        CryptoKeyType::Private));
    RETURN_IF_EXCEPTION(scope, {});
    if (!prepared)
        return {};
    KeyObject keyObject = WTF::move(*prepared);

    Structure* structure = globalObject->m_JSPrivateKeyObjectClassStructure.get(lexicalGlobalObject);
    JSPrivateKeyObject* privateKey = JSPrivateKeyObject::create(vm, structure, lexicalGlobalObject, WTF::move(keyObject));

    return privateKey;
}

} // namespace Bun
