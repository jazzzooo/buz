#include "config.h"
#include "ECDHKey.h"
#include "CryptoUtil.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include <new>

namespace Bun {

static void throwECDHError(JSC::JSGlobalObject* global, JSC::ThrowScope& scope, const ECDHError& error, bool converting = false)
{
    using Code = ECDHError::Code;
    auto crypto = [&](const char* message) { throwCryptoError(global, scope, error.cryptoCode, message); };
    switch (error.code) {
    case Code::outOfMemory:
        JSC::throwOutOfMemoryError(global, scope);
        return;
    case Code::invalidCurve:
        ERR::CRYPTO_INVALID_CURVE(scope, global);
        return;
    case Code::createKey:
        return crypto("Failed to create key using named curve");
    case Code::generateKey:
        return crypto("Failed to generate ECDH key pair");
    case Code::missingPublicKey:
        throwError(global, scope, ErrorCode::ERR_CRYPTO_INVALID_STATE, "Failed to get ECDH public key"_s);
        return;
    case Code::publicKeySize:
        return crypto(converting ? "Failed to get public key length" : "Failed to determine size for public key encoding");
    case Code::encodePublicKey:
        return crypto(converting ? "Failed to get public key" : "Failed to encode public key");
    case Code::missingPrivateKey:
        throwError(global, scope, ErrorCode::ERR_CRYPTO_INVALID_STATE, "Failed to get ECDH private key"_s);
        return;
    case Code::encodePrivateKey:
        throwError(global, scope, ErrorCode::ERR_CRYPTO_OPERATION_FAILED, "Failed to encode private key"_s);
        return;
    case Code::invalidKeyPair:
        ERR::CRYPTO_INVALID_KEYPAIR(scope, global);
        return;
    case Code::invalidPeerKey:
        ERR::CRYPTO_ECDH_INVALID_PUBLIC_KEY(scope, global);
        return;
    case Code::computeSecret:
        return crypto("Failed to compute ECDH key");
    case Code::decodePublicKey:
        return crypto("Failed to set EC_POINT from buffer");
    case Code::setPublicKey:
        return crypto("Failed to set EC_POINT as the public key");
    case Code::invalidPrivateKey:
        ERR::CRYPTO_INVALID_KEYTYPE(scope, global, "Private key is not valid for specified curve"_s);
        return;
    case Code::setPrivateKey:
        return crypto("Failed to set private key");
    case Code::derivePublicKey:
        return crypto("Failed to compute public key from private key");
    case Code::createGroup:
        return crypto("Failed to get EC_GROUP");
    case Code::convertPoint:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

static point_conversion_form_t ecdhPointFormat(const std::optional<std::optional<Bindgen::NodeCryptoECDHPointFormat>>& format)
{
    using Format = Bindgen::NodeCryptoECDHPointFormat;
    switch (format.value_or(std::nullopt).value_or(Format::uncompressed)) {
    case Format::uncompressed:
        return POINT_CONVERSION_UNCOMPRESSED;
    case Format::compressed:
        return POINT_CONVERSION_COMPRESSED;
    case Format::hybrid:
        return POINT_CONVERSION_HYBRID;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static Bindgen::NodeCryptoEncodedOutputResult encodeECDHResult(JSC::JSGlobalObject* global, JSC::ThrowScope& scope, ECDHKey::Result<WTF::Vector<uint8_t>> bytes, BufferEncodingType encoding, bool converting = false)
{
    if (!bytes) {
        throwECDHError(global, scope, bytes.error(), converting);
        return {};
    }
    return StringBytes::encode(global, scope, bytes->span(), encoding);
}

namespace Bindgen::Engine {

void destroyECDHKey(ECDHKey* key)
{
    delete key;
}

ECDHKey* bunBindgenEngine_NodeCryptoECDH_create(EngineCallContext& context, const BunBindgenEngine_NodeCryptoECDH_create_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    ncrypto::ClearErrorOnReturn clearError;
    auto key = ECDHKey::create(args.curve);
    if (!key) {
        throwECDHError(global, scope, key.error());
        return nullptr;
    }
    auto* result = new (std::nothrow) ECDHKey(WTF::move(*key));
    if (!result)
        JSC::throwOutOfMemoryError(global, scope);
    return result;
}

static void setECDHKey(EngineCallContext& context, const auto& args, ECDHKey::Result<void> (ECDHKey::*setKey)(std::span<const uint8_t>))
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto input = getStringOrBufferBytes(global, scope, args.input, nodeEncodingOrDefault(args.encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, void());
    ncrypto::ClearErrorOnReturn clearError;
    auto result = (args.key->*setKey)({ input->data(), input->size() });
    if (!result)
        throwECDHError(global, scope, result.error());
}

void bunBindgenEngine_NodeCryptoECDH_setPublicKey(EngineCallContext& context, const BunBindgenEngine_NodeCryptoECDH_setPublicKey_Arguments& args)
{
    setECDHKey(context, args, &ECDHKey::setPublicKey);
}

void bunBindgenEngine_NodeCryptoECDH_setPrivateKey(EngineCallContext& context, const BunBindgenEngine_NodeCryptoECDH_setPrivateKey_Arguments& args)
{
    setECDHKey(context, args, &ECDHKey::setPrivateKey);
}

}

namespace Bindgen::Cpp {

static ECDHKey& ecdhKey(BunBindgen_NodeCryptoECDH_ECDH_Native* owner)
{
    return *ZigExports::bunBindgenZig_NodeCryptoECDH_nativeKey(owner);
}

NodeCryptoEncodedOutputResult bunBindgenCpp_NodeCryptoECDH_ECDH_method_generateKeys(CppCallContext& context, const BunBindgenCpp_NodeCryptoECDH_ECDH_method_generateKeys_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    ncrypto::ClearErrorOnReturn clearError;
    auto& state = ecdhKey(args.bindingThis);
    auto key = state.generateCandidate();
    if (!key) {
        throwECDHError(global, scope, key.error());
        return {};
    }
    auto result = encodeECDHResult(global, scope, ECDHKey::publicKey(*key, ecdhPointFormat(args.format)), nodeEncodingOrDefault(args.encoding, BufferEncodingType::buffer));
    RETURN_IF_EXCEPTION(scope, {});
    state.commit(WTF::move(*key));
    return result;
}

NodeCryptoEncodedOutputResult bunBindgenCpp_NodeCryptoECDH_ECDH_method_getPublicKey(CppCallContext& context, const BunBindgenCpp_NodeCryptoECDH_ECDH_method_getPublicKey_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    ncrypto::ClearErrorOnReturn clearError;
    RELEASE_AND_RETURN(scope, encodeECDHResult(global, scope, ecdhKey(args.bindingThis).publicKey(ecdhPointFormat(args.format)), nodeEncodingOrDefault(args.encoding, BufferEncodingType::buffer)));
}

NodeCryptoEncodedOutputResult bunBindgenCpp_NodeCryptoECDH_ECDH_method_getPrivateKey(CppCallContext& context, const BunBindgenCpp_NodeCryptoECDH_ECDH_method_getPrivateKey_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    RELEASE_AND_RETURN(scope, encodeECDHResult(global, scope, ecdhKey(args.bindingThis).privateKey(), nodeEncodingOrDefault(args.encoding, BufferEncodingType::buffer)));
}

NodeCryptoEncodedOutputResult bunBindgenCpp_NodeCryptoECDH_ECDH_method_computeSecret(CppCallContext& context, const BunBindgenCpp_NodeCryptoECDH_ECDH_method_computeSecret_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    if (!args.key) {
        throwError(global, scope, ErrorCode::ERR_MISSING_ARGS, "ECDH.prototype.computeSecret requires a key argument"_s);
        return {};
    }
    std::optional<NodeStringEncoding> encoding;
    if (!convertStringInputEncodingAndLease(context, scope, *args.key, args.inputEncoding, encoding))
        return {};
    auto input = getStringOrBufferBytes(global, scope, *args.key, nodeEncodingOrDefault(encoding, BufferEncodingType::utf8));
    RETURN_IF_EXCEPTION(scope, {});
    ncrypto::ClearErrorOnReturn clearError;
    RELEASE_AND_RETURN(scope, encodeECDHResult(global, scope, ecdhKey(args.bindingThis).computeSecret({ input->data(), input->size() }), nodeEncodingOrDefault(args.outputEncoding, BufferEncodingType::buffer)));
}

BunBindgenCpp_NodeCryptoECDH_ECDH_static_method_convertKey_Return::Type bunBindgenCpp_NodeCryptoECDH_ECDH_static_method_convertKey(CppCallContext& context, const BunBindgenCpp_NodeCryptoECDH_ECDH_static_method_convertKey_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    ncrypto::ClearErrorOnReturn clearError;
    if (!args.curve) {
        ERR::INVALID_ARG_TYPE(scope, global, "curve"_s, "string"_s, JSC::jsUndefined());
        return {};
    }
    if (!args.key) {
        ERR::INVALID_ARG_TYPE(scope, global, "key"_s, "string or an instance of Buffer, TypedArray, or DataView"_s, JSC::jsUndefined());
        return {};
    }
    std::optional<NodeCryptoECDHInputEncoding> encoding;
    if (!convertStringInputEncodingAndLease(context, scope, *args.key, args.inputEncoding, encoding))
        return {};
    auto inputEncoding = encoding && encoding->is_encoding()
        ? nodeEncodingToBufferEncoding(encoding->encoding())
        : BufferEncodingType::utf8;
    auto input = getStringOrBufferBytes(global, scope, *args.key, inputEncoding);
    RETURN_IF_EXCEPTION(scope, {});
    auto converted = ECDHKey::convertKey(*args.curve, { input->data(), input->size() }, ecdhPointFormat(args.format));
    if (!converted && converted.error().code == ECDHError::Code::convertPoint) {
        bool allocationFailed = ERR_GET_REASON(converted.error().cryptoCode) == ERR_R_MALLOC_FAILURE;
        allocationFailed |= ncrypto::takeAllocationFailure();
        if (allocationFailed)
            return nativeAllocationFailure();
        using Errors = BunBindgenCpp_NodeCryptoECDH_ECDH_static_method_convertKey_Return::Errors;
        return std::unexpected(Errors::invalid_point {});
    }
    RELEASE_AND_RETURN(scope, encodeECDHResult(global, scope, WTF::move(converted), nodeEncodingOrDefault(args.outputEncoding, BufferEncodingType::buffer), true));
}

}
}
