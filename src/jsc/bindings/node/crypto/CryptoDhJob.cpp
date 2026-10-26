#include "CryptoDhJob.h"
#include "SchemaBindings.h"
#include "JSKeyObject.h"
#include "ErrorCode.h"

using namespace JSC;
using namespace ncrypto;

namespace {

bool isSupportedDiffieHellmanKey(const KeyObjectData& key)
{
    switch (key.asymmetricKey.id()) {
    case EVP_PKEY_DH:
    case EVP_PKEY_EC:
    case EVP_PKEY_X448:
    case EVP_PKEY_X25519:
        return true;
    default:
        return false;
    }
}

KeyObjectData* keyDataFromKeyObject(JSGlobalObject& global, Bun::JSKeyObject& keyObject, WTF::ASCIILiteral name, bool privateOnly)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    const auto& handle = keyObject.handle();
    if (privateOnly ? handle.type() != WebCore::CryptoKeyType::Private : handle.type() != WebCore::CryptoKeyType::Private && handle.type() != WebCore::CryptoKeyType::Public) {
        Bun::ERR::CRYPTO_INVALID_KEY_OBJECT_TYPE(
            scope,
            &global,
            handle.type(),
            privateOnly ? "private"_s : "public or private"_s);
        return nullptr;
    }

    auto data = handle.data();
    if (!isSupportedDiffieHellmanKey(*data)) {
        Bun::ERR::INVALID_ARG_VALUE(scope, &global, name, JSC::JSValue(&keyObject), "must be a supported key type"_s);
        return nullptr;
    }

    scope.release();
    return data.unsafeGet();
}

} // namespace

namespace Bun {

DhJobCtx::DhJobCtx(KeyObjectData* privateKey, KeyObjectData* publicKey)
    : m_privateKey(privateKey)
    , m_publicKey(publicKey)
{
}

void DhJobCtx::runTask()
{
    auto secret = DHPointer::stateless(m_privateKey->asymmetricKey, m_publicKey->asymmetricKey);
    if (!secret)
        return;

    WTF::Vector<uint8_t> result;
    result.append(secret.span());
    m_result = WTF::move(result);
}

std::optional<WTF::Vector<uint8_t>> DhJobCtx::takeResult()
{
    if (!m_result)
        return std::nullopt;

    auto result = WTF::move(*m_result);
    m_result.reset();
    return result;
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanCreate_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanCreate(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanCreate_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* privateKey = keyDataFromKeyObject(context.globalObject, *JSKeyObject::from(args.private_key), "options.privateKey"_s, true);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!privateKey)
        return std::nullopt;

    auto* publicKey = keyDataFromKeyObject(context.globalObject, *JSKeyObject::from(args.public_key), "options.publicKey"_s, false);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!publicKey)
        return std::nullopt;

    if (privateKey->asymmetricKey.id() != publicKey->asymmetricKey.id())
        return std::nullopt;

    scope.release();
    return new DhJobCtx(privateKey, publicKey);
}

void Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanRunTask(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanRunTask_Arguments& args)
{
    args.job->runTask();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanTakeResult_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanTakeResult(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoDiffieHellmanTakeResult_Arguments& args)
{
    return args.job->takeResult();
}

void Bindgen::Engine::releaseNodeCryptoDiffieHellmanJob(DhJobCtx* job)
{
    delete job;
}

} // namespace Bun
