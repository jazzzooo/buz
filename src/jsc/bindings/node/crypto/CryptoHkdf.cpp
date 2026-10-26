#include "CryptoHkdf.h"
#include "SchemaBindings.h"
#include "JSKeyObject.h"
#include "ErrorCode.h"
#include "JSDOMExceptionHandling.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include "webcrypto/CryptoKey.h"
#include "webcrypto/WebCryptoKey.h"

using namespace JSC;
using namespace WebCore;
using namespace ncrypto;

namespace {

Bun::Bindgen::NativeAllocationResult<WTF::Vector<uint8_t>> copyBytes(std::span<const uint8_t> bytes)
{
    WTF::Vector<uint8_t> result;
    if (!result.tryAppend(bytes))
        return Bun::Bindgen::nativeAllocationFailure();
    return result;
}

WTF::Vector<uint8_t> copySecretKeyBytes(JSGlobalObject* globalObject, ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto result = copyBytes(bytes);
    if (!result) {
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }
    return WTF::move(*result);
}

static Bun::JSKeyObject* nodeKeyObject(JSC::JSValue value)
{
    auto* key = dynamicDowncast<Bun::JSKeyObject>(value);
    RELEASE_ASSERT(key);
    return key;
}


} // namespace

namespace Bun {

WTF::Vector<uint8_t> exportSecretKeyBytes(JSGlobalObject* globalObject, ThrowScope& scope, const Bindgen::NodeSecretKeyObjectInput& value)
{
    if (value.is_key_object()) {
        const auto& key = nodeKeyObject(value.key_object())->handle();
        if (key.type() != CryptoKeyType::Secret) {
            ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, key.type(), "secret"_s);
            return {};
        }
        return copySecretKeyBytes(globalObject, scope, key.symmetricKey().span());
    }

    RELEASE_ASSERT(value.is_crypto_key());
    auto& cryptoKey = webCryptoKey(value.crypto_key());
    if (cryptoKey.type() != CryptoKeyType::Secret) {
        ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(scope, globalObject, cryptoKey.type(), "secret"_s);
        return {};
    }
    auto key = KeyObject::create(cryptoKey);
    if (key.hasException()) {
        WebCore::propagateException(*globalObject, scope, key.releaseException());
        return {};
    }
    auto keyObject = key.releaseReturnValue();
    return copySecretKeyBytes(globalObject, scope, keyObject.symmetricKey().span());
}

Bun::Bindgen::CppBytes Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoExportSecretKey(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_node_crypto_engine_nodeCryptoExportSecretKey_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    return exportSecretKeyBytes(&context.globalObject, scope, args.key);
}

HkdfJobCtx::HkdfJobCtx(
    Digest digest,
    size_t length,
    WTF::Vector<uint8_t>&& key,
    WTF::Vector<uint8_t>&& info,
    WTF::Vector<uint8_t>&& salt)
    : m_digest(digest)
    , m_length(length)
    , m_key(WTF::move(key))
    , m_info(WTF::move(info))
    , m_salt(WTF::move(salt))
{
}

HkdfJobCtx::~HkdfJobCtx()
{
    if (!m_key.isEmpty())
        memsetSpan(m_key.mutableSpan(), 0);
}

void HkdfJobCtx::runTask()
{
    if (m_length == 0) {
        m_result.emplace();
        return;
    }

    auto result = ncrypto::hkdf(
        m_digest,
        ncrypto::Buffer<const unsigned char>::from(m_key.span()),
        ncrypto::Buffer<const unsigned char>::from(m_info.span()),
        ncrypto::Buffer<const unsigned char>::from(m_salt.span()),
        m_length);
    if (result)
        m_result = ByteSource::allocated(result.release());
}

const EVP_MD* Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoResolveDigest(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoResolveDigest_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto digest = Digest::FromName(args.name);
    if (!digest) {
        ERR::CRYPTO_INVALID_DIGEST(scope, &context.globalObject, args.name);
        return nullptr;
    }

    scope.release();
    return digest.get();
}

Bindgen::NativeAllocationResult<std::optional<WTF::Vector<uint8_t>>> HkdfJobCtx::takeResult()
{
    if (!m_result)
        return std::optional<WTF::Vector<uint8_t>> {};

    auto result = copyBytes(m_result->span());
    if (!result)
        return Bindgen::nativeAllocationFailure();
    m_result.reset();
    return std::optional<WTF::Vector<uint8_t>> { WTF::move(*result) };
}

uint32_t Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoDigestSize(
    const BunBindgenEngine_node_crypto_engine_nodeCryptoDigestSize_Arguments& args)
{
    return static_cast<uint32_t>(Digest(args.digest).size());
}

Bindgen::NativeAllocationResult<HkdfJobCtx*> Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoHkdfCreate(
    const BunBindgenEngine_node_crypto_engine_nodeCryptoHkdfCreate_Arguments& args)
{
    auto key = copyBytes(args.key);
    if (!key)
        return Bindgen::nativeAllocationFailure();
    auto info = copyBytes(args.info);
    if (!info)
        return Bindgen::nativeAllocationFailure();
    auto salt = copyBytes(args.salt);
    if (!salt)
        return Bindgen::nativeAllocationFailure();
    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(HkdfJobCtx)).getValue(storage))
        return Bindgen::nativeAllocationFailure();
    return new (NotNull, storage) HkdfJobCtx(
        Digest(args.digest),
        args.length,
        WTF::move(*key),
        WTF::move(*info),
        WTF::move(*salt));
}

void Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoHkdfRunTask(
    const BunBindgenEngine_node_crypto_engine_nodeCryptoHkdfRunTask_Arguments& args)
{
    args.job->runTask();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoHkdfTakeResult_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoHkdfTakeResult(
    const BunBindgenEngine_node_crypto_engine_nodeCryptoHkdfTakeResult_Arguments& args)
{
    return args.job->takeResult();
}

void Bindgen::Engine::releaseNodeCryptoHkdfJob(HkdfJobCtx* job)
{
    delete job;
}

} // namespace Bun
