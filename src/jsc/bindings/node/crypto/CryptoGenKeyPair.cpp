#include "CryptoGenKeyPair.h"
#include "SchemaBindings.h"
#include "CryptoUtil.h"
#include "ErrorCode.h"
#include "BunProcess.h"
#include "openssl/ec.h"
#include "CryptoGenRsaKeyPair.h"
#include "CryptoGenDsaKeyPair.h"
#include "CryptoGenEcKeyPair.h"
#include "CryptoGenNidKeyPair.h"
#include "CryptoGenDhKeyPair.h"
#include "KeyObject.h"

using namespace JSC;

namespace Bun {

void KeyPairJobCtx::runTask()
{
    RELEASE_ASSERT(!m_hasRun);
    m_hasRun = true;
    ERR_clear_error();
    ncrypto::EVPKeyCtxPointer keyCtx = setup();
    if (keyCtx) {
        EVP_PKEY* pkey = nullptr;
        int status = EVP_PKEY_keygen(keyCtx.get(), &pkey);
        ncrypto::EVPKeyPointer key(pkey);
        if (status == 1)
            m_key = WTF::move(key);
    }
    while (auto error = ERR_get_error()) {
        if (m_key)
            continue;
        if (ERR_GET_REASON(error) == ERR_R_MALLOC_FAILURE)
            m_allocationFailed = true;
        if (!m_allocationFailed && !m_errors.tryAppend(error))
            m_allocationFailed = true;
    }
}

namespace {

using AsymmetricKeyKind = Bindgen::NodeCryptoAsymmetricKeyKind;
using KeyPairOptions = Bindgen::NodeCryptoKeyPairOptions;

template<typename Job, typename... Args>
std::unique_ptr<KeyPairJobCtx> tryCreateKeyPairJob(JSGlobalObject* globalObject, ThrowScope& scope, Args&&... args)
{
    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(Job)).getValue(storage)) {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }
    return std::unique_ptr<KeyPairJobCtx>(new (NotNull, storage) Job(std::forward<Args>(args)...));
}

template<typename... Fields>
bool prefetch(const Fields&... fields)
{
    return (fields.prefetch() && ...);
}

ncrypto::EVPKeyPointer::PKFormatType keyExportFormat(Bindgen::NodeCryptoKeyExportFormat format)
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

ncrypto::EVPKeyPointer::PKEncodingType publicKeyExportType(Bindgen::NodeCryptoPublicKeyExportType type)
{
    switch (type) {
    case Bindgen::NodeCryptoPublicKeyExportType::pkcs1:
        return ncrypto::EVPKeyPointer::PKEncodingType::PKCS1;
    case Bindgen::NodeCryptoPublicKeyExportType::spki:
        return ncrypto::EVPKeyPointer::PKEncodingType::SPKI;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

ncrypto::EVPKeyPointer::PKEncodingType privateKeyExportType(Bindgen::NodeCryptoPrivateKeyExportType type)
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

bool parsePublicKeyEncoding(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    AsymmetricKeyKind keyKind,
    const std::optional<Bindgen::NodeCryptoKeyPairPublicKeyEncoding>& input,
    ncrypto::EVPKeyPointer::PublicKeyEncodingConfig& config)
{
    if (!input) {
        config.output_key_object = true;
        return true;
    }
    const auto& encoding = *input;
    config.format = keyExportFormat(encoding.format);
    if (!encoding.type) {
        if (encoding.format != Bindgen::NodeCryptoKeyExportFormat::jwk) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "options.publicKeyEncoding.type"_s, jsUndefined());
            return false;
        }
        return true;
    }
    if (*encoding.type == Bindgen::NodeCryptoPublicKeyExportType::pkcs1 && keyKind != AsymmetricKeyKind::rsa) {
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, globalObject, "pkcs1"_s, "can only be used for RSA keys"_s);
        return false;
    }
    config.type = publicKeyExportType(*encoding.type);
    return true;
}

bool parsePrivateKeyEncoding(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    AsymmetricKeyKind keyKind,
    const std::optional<Bindgen::NodeCryptoKeyPairPrivateKeyEncoding>& input,
    ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig& config)
{
    if (!input) {
        config.output_key_object = true;
        return true;
    }
    const auto& encoding = *input;
    const auto* format = encoding.format.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!format)
        return false;
    const auto* type = encoding.type.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!type)
        return false;

    config.format = keyExportFormat(*format);
    if (!type->has_value()) {
        if (*format != Bindgen::NodeCryptoKeyExportFormat::jwk) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "options.privateKeyEncoding.type"_s, jsUndefined());
            return false;
        }
    } else {
        if (type->value() == Bindgen::NodeCryptoPrivateKeyExportType::pkcs1 && keyKind != AsymmetricKeyKind::rsa) {
            ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, globalObject, "pkcs1"_s, "can only be used for RSA keys"_s);
            return false;
        }
        if (type->value() == Bindgen::NodeCryptoPrivateKeyExportType::sec1 && keyKind != AsymmetricKeyKind::ec) {
            ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, globalObject, "sec1"_s, "can only be used for EC keys"_s);
            return false;
        }
        config.type = privateKeyExportType(type->value());
    }

    if (!prefetch(encoding.cipher, encoding.passphrase, encoding.encoding))
        return false;
    RETURN_IF_EXCEPTION(scope, false);

    const auto* cipher = encoding.cipher.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!cipher)
        return false;
    const auto* inputEncoding = encoding.encoding.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!inputEncoding)
        return false;

    if (cipher->has_value() && *format == Bindgen::NodeCryptoKeyExportFormat::der && type->has_value() &&
        (type->value() == Bindgen::NodeCryptoPrivateKeyExportType::pkcs1 || type->value() == Bindgen::NodeCryptoPrivateKeyExportType::sec1)) {
        auto typeName = type->value() == Bindgen::NodeCryptoPrivateKeyExportType::pkcs1 ? "pkcs1"_s : "sec1"_s;
        ERR::CRYPTO_INCOMPATIBLE_KEY_OPTIONS(scope, globalObject, typeName, "does not support encryption"_s);
        return false;
    }

    if (!cipher->has_value() && !encoding.passphrase.prefetchedIsUndefined()) {
        ERR::INVALID_ARG_VALUE(scope, globalObject, "options.privateKeyEncoding.cipher"_s, jsUndefined());
        return false;
    }
    const auto* passphrase = encoding.passphrase.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!passphrase)
        return false;
    if (cipher->has_value() && !passphrase->has_value()) {
        ERR::INVALID_ARG_VALUE(scope, globalObject, "options.privateKeyEncoding.passphrase"_s, jsUndefined());
        return false;
    }

    if (passphrase->has_value()) {
        const auto& value = passphrase->value();
        BufferEncodingType bufferEncoding = BufferEncodingType::utf8;
        if (value.is_string() && inputEncoding->has_value()) {
            const auto& selectedEncoding = inputEncoding->value();
            if (selectedEncoding.is_string_encoding()) {
                bufferEncoding = nodeEncodingToBufferEncoding(selectedEncoding.string_encoding());
            } else if (selectedEncoding.is_buffer_encoding()) {
                bufferEncoding = BufferEncodingType::buffer;
            } else if (selectedEncoding.is_text()) {
                ERR::UNKNOWN_ENCODING(scope, globalObject, WTF::StringView(selectedEncoding.text()));
                return false;
            }
        }
        auto bytes = getStringOrBufferBytes(globalObject, scope, value, bufferEncoding);
        RETURN_IF_EXCEPTION(scope, false);

        auto copied = ncrypto::DataPointer::FromSpan(bytes.data);
        if (!bytes->empty() && !copied) {
            throwOutOfMemoryError(globalObject, scope);
            return false;
        }
        config.passphrase = WTF::move(copied);
    }

    if (cipher->has_value()) {
        config.cipher = ncrypto::getCipherByName(WTF::StringView(cipher->value()));
        if (!config.cipher) {
            ERR::CRYPTO_UNKNOWN_CIPHER(scope, globalObject, cipher->value());
            return false;
        }
    }
    return true;
}

bool parseKeyEncodingConfig(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    AsymmetricKeyKind keyKind,
    const KeyPairOptions* options,
    KeyEncodingConfig& config)
{
    if (!options) {
        config.publicKeyEncoding.output_key_object = true;
        config.privateKeyEncoding.output_key_object = true;
        return true;
    }

    const auto* publicInput = options->public_key_encoding.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!publicInput)
        return false;
    if (!parsePublicKeyEncoding(globalObject, scope, keyKind, *publicInput, config.publicKeyEncoding))
        return false;
    const auto* privateInput = options->private_key_encoding.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!privateInput)
        return false;

    return parsePrivateKeyEncoding(globalObject, scope, keyKind, *privateInput, config.privateKeyEncoding);
}

const KeyPairOptions* requireOptions(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const std::optional<KeyPairOptions>& options)
{
    if (options)
        return &*options;
    ERR::INVALID_ARG_TYPE(scope, globalObject, "options"_s, "object"_s, jsUndefined());
    return nullptr;
}

const WTF::String* deprecatedHashOption(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const Bindgen::CppLazyArgument<std::optional<WTF::String>>& option,
    ASCIILiteral warning)
{
    if (!option.prefetchedIsUndefined())
        Process::emitWarning(globalObject, warning, "DeprecationWarning"_s, "DEP0154"_s);
    RETURN_IF_EXCEPTION(scope, nullptr);
    const auto* converted = option.convert();
    RETURN_IF_EXCEPTION(scope, nullptr);
    return converted && converted->has_value() ? &converted->value() : nullptr;
}

std::unique_ptr<KeyPairJobCtx> prepareKeyPair(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const Bindgen::NodeCryptoKeyPairRequest& request)
{
    const KeyPairOptions* options = request.options ? &*request.options : nullptr;

    KeyEncodingConfig encodingConfig;
    if (!parseKeyEncodingConfig(globalObject, scope, request.type, options, encodingConfig))
        return nullptr;
    RETURN_IF_EXCEPTION(scope, nullptr);

    switch (request.type) {
    case AsymmetricKeyKind::rsa:
    case AsymmetricKeyKind::rsa_pss: {
        options = requireOptions(globalObject, scope, request.options);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!options)
            return nullptr;

        const auto* modulusLength = options->modulus_length.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!modulusLength)
            return nullptr;
        const auto* publicExponent = options->public_exponent.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!publicExponent)
            return nullptr;
        uint32_t exponent = publicExponent->value_or(ncrypto::EVPKeyCtxPointer::kDefaultRsaExponent);

        if (request.type == AsymmetricKeyKind::rsa) {
            return tryCreateKeyPairJob<RsaKeyPairJobCtx>(
                globalObject, scope,
                RsaKeyVariant::RSA_SSA_PKCS1_v1_5,
                *modulusLength,
                exponent,
                WTF::move(encodingConfig));
        }

        if (!prefetch(
                options->hash_algorithm,
                options->mgf1_hash_algorithm,
                options->salt_length,
                options->hash,
                options->mgf1_hash))
            return nullptr;
        RETURN_IF_EXCEPTION(scope, nullptr);

        const auto* hashAlgorithm = options->hash_algorithm.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!hashAlgorithm)
            return nullptr;
        const auto* mgf1HashAlgorithm = options->mgf1_hash_algorithm.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!mgf1HashAlgorithm)
            return nullptr;
        const auto* saltLength = options->salt_length.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!saltLength)
            return nullptr;
        const auto* deprecatedHash = deprecatedHashOption(
            globalObject,
            scope,
            options->hash,
            "\"options.hash\" is deprecated, use \"options.hashAlgorithm\" instead."_s);
        RETURN_IF_EXCEPTION(scope, nullptr);
        const auto* deprecatedMgf1Hash = deprecatedHashOption(
            globalObject,
            scope,
            options->mgf1_hash,
            "\"options.mgf1Hash\" is deprecated, use \"options.mgf1HashAlgorithm\" instead."_s);
        RETURN_IF_EXCEPTION(scope, nullptr);

        if (hashAlgorithm->has_value() && deprecatedHash && hashAlgorithm->value() != *deprecatedHash) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "options.hash"_s, jsString(globalObject->vm(), *deprecatedHash));
            return nullptr;
        }
        if (mgf1HashAlgorithm->has_value() && deprecatedMgf1Hash && mgf1HashAlgorithm->value() != *deprecatedMgf1Hash) {
            ERR::INVALID_ARG_VALUE(scope, globalObject, "options.mgf1Hash"_s, jsString(globalObject->vm(), *deprecatedMgf1Hash));
            return nullptr;
        }

        const WTF::String* hashName = hashAlgorithm->has_value() ? &hashAlgorithm->value() : deprecatedHash;
        const WTF::String* mgf1HashName = mgf1HashAlgorithm->has_value() ? &mgf1HashAlgorithm->value() : deprecatedMgf1Hash;
        ncrypto::Digest digest = nullptr;
        ncrypto::Digest mgf1Digest = nullptr;
        if (hashName) {
            digest = ncrypto::Digest::FromName(WTF::StringView(*hashName));
            if (!digest) {
                ERR::CRYPTO_INVALID_DIGEST(scope, globalObject, WTF::StringView(*hashName));
                return nullptr;
            }
        }
        if (mgf1HashName) {
            mgf1Digest = ncrypto::Digest::FromName(WTF::StringView(*mgf1HashName));
            if (!mgf1Digest) {
                ERR::CRYPTO_INVALID_DIGEST(scope, globalObject, "Invalid MGF1 digest: "_s, WTF::StringView(*mgf1HashName));
                return nullptr;
            }
        }

        return tryCreateKeyPairJob<RsaKeyPairJobCtx>(
            globalObject, scope,
            RsaKeyVariant::RSA_PSS,
            *modulusLength,
            exponent,
            *saltLength,
            digest,
            mgf1Digest,
            WTF::move(encodingConfig));
    }
    case AsymmetricKeyKind::dsa: {
        options = requireOptions(globalObject, scope, request.options);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!options)
            return nullptr;
        const auto* modulusLength = options->modulus_length.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!modulusLength)
            return nullptr;
        const auto* divisorLength = options->divisor_length.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!divisorLength)
            return nullptr;
        return tryCreateKeyPairJob<DsaKeyPairJobCtx>(globalObject, scope, *modulusLength, *divisorLength, WTF::move(encodingConfig));
    }
    case AsymmetricKeyKind::ec: {
        options = requireOptions(globalObject, scope, request.options);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!options)
            return nullptr;
        const auto* namedCurve = options->named_curve.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!namedCurve)
            return nullptr;
        const auto* paramEncoding = options->param_encoding.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!paramEncoding)
            return nullptr;

        auto curveName = namedCurve->tryGetUTF8();
        if (!curveName) {
            throwOutOfMemoryError(globalObject, scope);
            return nullptr;
        }
        int curveNid = ncrypto::Ec::GetCurveIdFromName(curveName->data());
        if (curveNid == NID_undef) {
            ERR::CRYPTO_INVALID_CURVE(scope, globalObject);
            return nullptr;
        }
        int encoding = OPENSSL_EC_NAMED_CURVE;
        if (paramEncoding->has_value() && paramEncoding->value() == Bindgen::NodeCryptoKeyPairParamEncoding::explicit_curve)
            encoding = OPENSSL_EC_EXPLICIT_CURVE;
        return tryCreateKeyPairJob<EcKeyPairJobCtx>(globalObject, scope, curveNid, encoding, WTF::move(encodingConfig));
    }
    case AsymmetricKeyKind::ed25519:
        return tryCreateKeyPairJob<NidKeyPairJobCtx>(globalObject, scope, EVP_PKEY_ED25519, WTF::move(encodingConfig));
    case AsymmetricKeyKind::ed448:
        return tryCreateKeyPairJob<NidKeyPairJobCtx>(globalObject, scope, EVP_PKEY_ED448, WTF::move(encodingConfig));
    case AsymmetricKeyKind::x25519:
        return tryCreateKeyPairJob<NidKeyPairJobCtx>(globalObject, scope, EVP_PKEY_X25519, WTF::move(encodingConfig));
    case AsymmetricKeyKind::x448:
        return tryCreateKeyPairJob<NidKeyPairJobCtx>(globalObject, scope, EVP_PKEY_X448, WTF::move(encodingConfig));
    case AsymmetricKeyKind::dh: {
        options = requireOptions(globalObject, scope, request.options);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!options)
            return nullptr;
        if (!prefetch(options->group, options->prime_length, options->prime, options->generator))
            return nullptr;
        RETURN_IF_EXCEPTION(scope, nullptr);

        const bool hasGroup = !options->group.prefetchedIsUndefinedOrNull();
        const bool hasPrimeLength = !options->prime_length.prefetchedIsUndefinedOrNull();
        const bool hasPrime = !options->prime.prefetchedIsUndefinedOrNull();
        const bool hasGenerator = !options->generator.prefetchedIsUndefinedOrNull();
        if (hasGroup) {
            if (hasPrime) {
                ERR::INCOMPATIBLE_OPTION_PAIR(scope, globalObject, "group"_s, "prime"_s);
                return nullptr;
            }
            if (hasPrimeLength) {
                ERR::INCOMPATIBLE_OPTION_PAIR(scope, globalObject, "group"_s, "primeLength"_s);
                return nullptr;
            }
            if (hasGenerator) {
                ERR::INCOMPATIBLE_OPTION_PAIR(scope, globalObject, "group"_s, "generator"_s);
                return nullptr;
            }
            const auto* groupName = options->group.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!groupName || !groupName->has_value())
                return nullptr;
            ncrypto::ClearErrorOnReturn clearError;
            auto group = ncrypto::DHPointer::FromGroup(WTF::StringView(groupName->value()));
            if (!group) {
                if (ncrypto::takeAllocationFailure()) {
                    throwOutOfMemoryError(globalObject, scope);
                    return nullptr;
                }
                ERR::CRYPTO_UNKNOWN_DH_GROUP(scope, globalObject);
                return nullptr;
            }
            return tryCreateKeyPairJob<DhKeyPairJobCtx>(globalObject, scope, WTF::move(group), WTF::move(encodingConfig));
        }

        if (hasPrime && hasPrimeLength) {
            ERR::INCOMPATIBLE_OPTION_PAIR(scope, globalObject, "prime"_s, "primeLength"_s);
            return nullptr;
        }
        if (!hasPrime && !hasPrimeLength) {
            ERR::MISSING_OPTION(scope, globalObject, "At least one of the group, prime, or primeLength options"_s);
            return nullptr;
        }

        if (hasPrimeLength) {
            const auto* primeLength = options->prime_length.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!primeLength || !primeLength->has_value())
                return nullptr;
            const auto* generator = options->generator.convert();
            RETURN_IF_EXCEPTION(scope, nullptr);
            if (!generator)
                return nullptr;
            uint32_t generatorValue = static_cast<uint32_t>(generator->value_or(2));
            return tryCreateKeyPairJob<DhKeyPairJobCtx>(globalObject, scope, primeLength->value(), generatorValue, WTF::move(encodingConfig));
        }

        const auto* primeBytes = options->prime.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!primeBytes || !primeBytes->has_value())
            return nullptr;
        ncrypto::ClearErrorOnReturn clearError;
        ncrypto::BignumPointer prime(primeBytes->value().data(), primeBytes->value().size());
        if (!prime) {
            if (ncrypto::takeAllocationFailure()) {
                throwOutOfMemoryError(globalObject, scope);
                return nullptr;
            }
            ERR::OUT_OF_RANGE(scope, globalObject, "prime is too big"_s);
            return nullptr;
        }
        const auto* generator = options->generator.convert();
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!generator)
            return nullptr;
        uint32_t generatorValue = static_cast<uint32_t>(generator->value_or(2));
        return tryCreateKeyPairJob<DhKeyPairJobCtx>(globalObject, scope, WTF::move(prime), generatorValue, WTF::move(encodingConfig));
    }
    }
    RELEASE_ASSERT_NOT_REACHED();
}

} // namespace

KeyPairJobCtx* Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoKeyPairCreate(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoKeyPairCreate_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto prepared = prepareKeyPair(globalObject, scope, args.request);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* job = prepared.release();
    RELEASE_ASSERT(job);
    scope.release();
    return job;
}

Bindgen::NativeAllocationResult<void> Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoKeyPairRunTask(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoKeyPairRunTask_Arguments& args)
{
    args.job->runTask();
    if (args.job->allocationFailed())
        return Bindgen::nativeAllocationFailure();
    return {};
}

Bindgen::NodeCryptoKeyPairResultResult Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoKeyPairResult(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoKeyPairResult_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!args.job->m_key) {
        if (args.job->errors().empty())
            throwError(globalObject, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "key generation failed"_s);
        else
            throwCapturedCryptoError(globalObject, scope, args.job->errors(), "key generation failed");
        return {};
    }
    RELEASE_ASSERT(EVP_PKEY_up_ref(args.job->m_key.get()));
    auto data = KeyObjectData::tryCreate(ncrypto::EVPKeyPointer(args.job->m_key.get()));
    if (!data) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    auto keyObject = KeyObject::create(CryptoKeyType::Private, WTF::move(data));

    Bindgen::NodeCryptoKeyPairResultResult result;
    if (args.job->m_publicKeyEncoding.output_key_object) {
        auto publicKey = keyObject.exportPublic(globalObject, scope, args.job->m_publicKeyEncoding);
        RETURN_IF_EXCEPTION(scope, {});
        result.public_key.set_key_object(publicKey);
    } else {
        auto publicKey = keyObject.exportPublicResult(globalObject, scope, args.job->m_publicKeyEncoding);
        RETURN_IF_EXCEPTION(scope, {});
        result.public_key.set_exported(WTF::move(publicKey));
    }
    if (args.job->m_privateKeyEncoding.output_key_object) {
        auto privateKey = keyObject.exportPrivate(globalObject, scope, args.job->m_privateKeyEncoding);
        RETURN_IF_EXCEPTION(scope, {});
        result.private_key.set_key_object(privateKey);
    } else {
        auto privateKey = keyObject.exportPrivateResult(globalObject, scope, args.job->m_privateKeyEncoding);
        RETURN_IF_EXCEPTION(scope, {});
        result.private_key.set_exported(WTF::move(privateKey));
    }
    scope.release();
    return result;
}

void Bindgen::Engine::releaseNodeCryptoKeyPairJob(KeyPairJobCtx* job)
{
    delete job;
}

} // namespace Bun
