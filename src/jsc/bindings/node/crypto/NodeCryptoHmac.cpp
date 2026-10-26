#include "config.h"
#include "CryptoUtil.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include <array>
#include <openssl/hmac.h>

namespace Bun::Bindgen::Engine {

void releaseHmacContext(HMAC_CTX* context)
{
    HMAC_CTX_free(context);
}

uint64_t bunBindgenEngine_NodeCryptoHmac_contextSize(const BunBindgenEngine_NodeCryptoHmac_contextSize_Arguments&)
{
    return sizeof(HMAC_CTX);
}

HMAC_CTX* bunBindgenEngine_NodeCryptoHmac_create(EngineCallContext& context, const BunBindgenEngine_NodeCryptoHmac_create_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    WTF::Vector<uint8_t> exportedKey;
    if (args.key.is_key_object()) {
        exportedKey = exportSecretKeyBytes(global, scope, args.key.key_object());
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    auto key = getSecretKeyMaterial(global, scope, args.key, nodeEncodingOrDefault(args.encoding, BufferEncodingType::utf8), exportedKey.span());
    RETURN_IF_EXCEPTION(scope, nullptr);
    const auto* digest = ncrypto::getDigestByName(args.algorithm);
    if (!digest) {
        ERR::CRYPTO_INVALID_DIGEST(scope, global, args.algorithm);
        return nullptr;
    }
    auto hmac = ncrypto::HMACCtxPointer::New();
    if (!hmac) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    if (!hmac.init({ .data = key->data(), .len = key->size() }, digest)) {
        throwCryptoError(global, scope, ERR_get_error(), "Failed to initialize HMAC context");
        return nullptr;
    }
    return hmac.release();
}

void bunBindgenEngine_NodeCryptoHmac_update(EngineCallContext& context, const BunBindgenEngine_NodeCryptoHmac_update_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto input = getStringOrBufferBytes(global, scope, args.input, nodeEncodingOrDefault(args.encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, void());
    if (!HMAC_Update(args.hmac, input->data(), input->size()))
        ERR::CRYPTO_HASH_UPDATE_FAILED(scope, global);
}

NodeCryptoEncodedOutputResult bunBindgenEngine_NodeCryptoHmac_digest(EngineCallContext& context, const BunBindgenEngine_NodeCryptoHmac_digest_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto encoding = nodeEncodingOrDefault(args.encoding, BufferEncodingType::buffer);
    if (!args.hmac)
        RELEASE_AND_RETURN(scope, StringBytes::encode(global, scope, {}, encoding));
    std::array<uint8_t, EVP_MAX_MD_SIZE> bytes;
    unsigned length = bytes.size();
    if (!HMAC_Final(*args.hmac, bytes.data(), &length)) {
        throwCryptoError(global, scope, ERR_get_error(), "Failed to digest HMAC");
        return {};
    }
    RELEASE_ASSERT(length <= bytes.size());
    RELEASE_AND_RETURN(scope, StringBytes::encode(global, scope, std::span<const uint8_t>(bytes).first(length), encoding));
}

}
