#include "CryptoSignJob.h"
#include "SchemaBindings.h"
#include "ErrorCode.h"
#include <openssl/rsa.h>
#include <wtf/Scope.h>

using namespace JSC;
using namespace ncrypto;
using namespace WebCore;

namespace {

std::optional<Bun::NodeCryptoSigningKey> signingKeyFromInput(JSGlobalObject& global, const Bun::Bindgen::NodeCryptoAsymmetricKeyInput& input, bool verify)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());

    std::optional<int32_t> padding;
    std::optional<int32_t> saltLength;
    Bun::DSASigEnc dsaSigEnc = Bun::DSASigEnc::DER;
    if (input.is_options()) {
        const auto& options = input.options();
        const auto* convertedPadding = options.padding.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        const auto* convertedSaltLength = options.salt_length.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        const auto* convertedDsaEncoding = options.dsa_encoding.convert();
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!convertedPadding || !convertedSaltLength || !convertedDsaEncoding)
            return std::nullopt;
        padding = *convertedPadding;
        saltLength = *convertedSaltLength;
        if (convertedDsaEncoding->value_or(Bun::Bindgen::NodeCryptoDsaEncoding::der) == Bun::Bindgen::NodeCryptoDsaEncoding::p1363)
            dsaSigEnc = Bun::DSASigEnc::P1363;
    }

    auto keyData = Bun::KeyObject::prepareAsymmetricKey(
        &global,
        scope,
        input,
        verify ? Bun::KeyObject::PrepareAsymmetricKeyMode::ConsumePublic : Bun::KeyObject::PrepareAsymmetricKeyMode::ConsumePrivate);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!keyData)
        return std::nullopt;

    scope.release();
    return Bun::NodeCryptoSigningKey { WTF::move(keyData), padding, saltLength, dsaSigEnc };
}

} // namespace

namespace Bun {

std::optional<NodeCryptoSigningKey> createNodeCryptoSigningKey(JSGlobalObject& global, const Bindgen::NodeCryptoAsymmetricKeyInput& input, bool verify)
{
    return signingKeyFromInput(global, input, verify);
}

SignJobCtx::SignJobCtx(Mode mode, NodeCryptoSigningKey&& key, WTF::Vector<uint8_t>&& data, Digest digest, WTF::Vector<uint8_t>&& signature, bool valid)
    : m_mode(mode)
    , m_keyData(WTF::move(key.keyData))
    , m_data(WTF::move(data))
    , m_signature(WTF::move(signature))
    , m_digest(digest)
    , m_padding(key.padding)
    , m_saltLength(key.saltLength)
    , m_dsaSigEnc(key.dsaSigEnc)
    , m_valid(valid)
{
    if (!valid)
        m_verifyResult = false;
}

SignJobCtx* SignJobCtx::tryCreate(Mode mode, NodeCryptoSigningKey&& key, std::span<const uint8_t> data, Digest digest, std::span<const uint8_t> signature)
{
    WTF::Vector<uint8_t> ownedData;
    if (!ownedData.tryAppend(data))
        return nullptr;
    WTF::Vector<uint8_t> ownedSignature;
    bool valid = true;
    if (mode == Mode::Verify) {
        if (key.keyData->asymmetricKey.isSigVariant() && key.dsaSigEnc == DSASigEnc::P1363) {
            switch (convertP1363ToDER(Buffer<const uint8_t>::from(signature), key.keyData->asymmetricKey, ownedSignature)) {
            case SignatureConversionResult::out_of_memory:
                return nullptr;
            case SignatureConversionResult::invalid:
                valid = false;
                break;
            case SignatureConversionResult::converted:
                break;
            }
        } else if (!ownedSignature.tryAppend(signature))
            return nullptr;
    }
    if (!digest && key.keyData->asymmetricKey.isRsaVariant())
        digest = Digest::FromName("SHA256"_s);
    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(SignJobCtx)).getValue(storage))
        return nullptr;
    return new (NotNull, storage) SignJobCtx(mode, WTF::move(key), WTF::move(ownedData), digest, WTF::move(ownedSignature), valid);
}

void SignJobCtx::runTask()
{
    RELEASE_ASSERT(!m_hasRun);
    m_hasRun = true;
    if (!m_valid)
        return;

    ClearErrorOnReturn clearError;
    auto captureFailure = makeScopeExit([&] {
        bool succeeded = m_mode == Mode::Sign ? m_signResult.has_value() : m_verifyResult.value_or(false);
        if (ncrypto::takeAllocationFailure() && !succeeded)
            m_allocationFailed = true;
    });
    auto context = EVPMDCtxPointer::New();
    if (!context) {
        m_allocationFailed = true;
        return;
    }

    const auto& key = m_keyData->asymmetricKey;
    std::optional<EVP_PKEY_CTX*> keyContext = m_mode == Mode::Sign
        ? context.signInit(key, m_digest)
        : context.verifyInit(key, m_digest);
    if (!keyContext)
        return;

    int32_t padding = m_padding.value_or(key.getDefaultSignPadding());
    if (key.isRsaVariant()) {
        std::optional<int> saltLength = m_saltLength;
        if (padding == RSA_PKCS1_PSS_PADDING && !saltLength)
            saltLength = RSA_PSS_SALTLEN_AUTO;
        if (!EVPKeyCtxPointer::setRsaPadding(*keyContext, padding, saltLength))
            return;
    }

    auto data = ncrypto::Buffer<const uint8_t> { .data = m_data.begin(), .len = m_data.size() };
    if (m_mode == Mode::Verify) {
        auto signature = ncrypto::Buffer<const uint8_t> { .data = m_signature.begin(), .len = m_signature.size() };
        m_verifyResult = context.verify(data, signature);
        return;
    }

    auto encoded = key.isOneShotVariant() ? context.signOneShot(data) : context.sign(data);
    if (!encoded)
        return;

    if (key.isSigVariant() && m_dsaSigEnc == DSASigEnc::P1363) {
        const uint32_t componentLength = key.getBytesOfRS().value_or(std::numeric_limits<uint32_t>::max());
        if (componentLength == std::numeric_limits<uint32_t>::max())
            return;

        auto p1363 = DataPointer::Alloc(static_cast<size_t>(componentLength) * 2);
        if (!p1363) {
            m_allocationFailed = true;
            return;
        }
        p1363.zero();
        if (!ncrypto::extractP1363(
                ncrypto::Buffer<const uint8_t> { .data = encoded.get<const uint8_t>(), .len = encoded.size() },
                p1363.get<uint8_t>(),
                componentLength))
            return;

        WTF::Vector<uint8_t> result;
        if (!result.tryAppend(p1363.span())) {
            m_allocationFailed = true;
            return;
        }
        m_signResult = WTF::move(result);
        return;
    }

    WTF::Vector<uint8_t> result;
    if (!result.tryAppend(encoded.span())) {
        m_allocationFailed = true;
        return;
    }
    m_signResult = WTF::move(result);
}

std::optional<WTF::Vector<uint8_t>> SignJobCtx::takeSignResult()
{
    if (!m_signResult)
        return std::nullopt;
    auto result = WTF::move(*m_signResult);
    m_signResult.reset();
    return result;
}

std::optional<bool> SignJobCtx::takeVerifyResult()
{
    auto result = m_verifyResult;
    m_verifyResult.reset();
    return result;
}

SignJobCtx* Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoSignCreate(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoSignCreate_Arguments& args)
{
    auto key = signingKeyFromInput(context.globalObject, args.key, false);
    if (!key)
        return nullptr;
    auto digest = args.digest
        ? Digest(args.digest.value())
        : Digest {};
    auto* result = SignJobCtx::tryCreate(SignJobCtx::Mode::Sign, WTF::move(*key), args.data, digest);
    if (!result) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwOutOfMemoryError(&context.globalObject, scope);
    }
    return result;
}

SignJobCtx* Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoVerifyCreate(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoVerifyCreate_Arguments& args)
{
    auto key = signingKeyFromInput(context.globalObject, args.key, true);
    if (!key)
        return nullptr;
    auto digest = args.digest
        ? Digest(args.digest.value())
        : Digest {};
    auto* result = SignJobCtx::tryCreate(SignJobCtx::Mode::Verify, WTF::move(*key), args.data, digest, args.signature);
    if (!result) {
        auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
        throwOutOfMemoryError(&context.globalObject, scope);
    }
    return result;
}

void Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoSignRunTask(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoSignRunTask_Arguments& args)
{
    args.job->runTask();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoSignTakeResult_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoSignTakeResult(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoSignTakeResult_Arguments& args)
{
    if (args.job->allocationFailed())
        return Bindgen::nativeAllocationFailure();
    return args.job->takeSignResult();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoVerifyTakeResult_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoVerifyTakeResult(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoVerifyTakeResult_Arguments& args)
{
    if (args.job->allocationFailed())
        return Bindgen::nativeAllocationFailure();
    return args.job->takeVerifyResult();
}

void Bindgen::Engine::releaseNodeCryptoSignJob(SignJobCtx* job)
{
    delete job;
}

} // namespace Bun
