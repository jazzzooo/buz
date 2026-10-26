#include "root.h"
#include "helpers.h"
#include "ErrorCode.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "ZigGlobalObject.h"
#include "webcrypto/CryptoKeyOKP.h"
#include "webcrypto/CryptoKeyEC.h"
#include "webcrypto/CryptoKeyRSA.h"
#include "webcrypto/CryptoKeyAES.h"
#include "webcrypto/CryptoKeyHMAC.h"
#include "webcrypto/CryptoKeyRaw.h"
#include "webcrypto/CryptoKeyUsage.h"
#include <openssl/evp.h>
#include <openssl/mem.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/curve25519.h>
#include "CryptoAlgorithmHMAC.h"
#include "CryptoAlgorithmEd25519.h"
#include "CryptoAlgorithmRSA_OAEP.h"
#include "CryptoAlgorithmRSA_PSS.h"
#include "CryptoAlgorithmRSASSA_PKCS1_v1_5.h"
#include "CryptoAlgorithmECDSA.h"
#include "CryptoAlgorithmEcdsaParams.h"
#include "CryptoAlgorithmRsaOaepParams.h"
#include "CryptoAlgorithmRsaPssParams.h"
#include "CryptoAlgorithmRegistry.h"
#include "wtf/ForbidHeapAllocation.h"
#include "wtf/Noncopyable.h"
#include "ncrypto.h"
#include "AsymmetricKeyValue.h"
#include "NodeValidator.h"
#include "JSHash.h"
#include "JSCipher.h"
#include "JSDiffieHellman.h"
#include "JSDiffieHellmanGroup.h"
#include "JSKeyObject.h"
#include "JSSecretKeyObject.h"
#include "JSPublicKeyObject.h"
#include "JSPrivateKeyObject.h"
#include "CryptoUtil.h"
#include "JSDOMExceptionHandling.h"

using namespace JSC;

namespace Bun {

WTF::Vector<WTF::String> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_getCurves(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_getCurves_Arguments&)
{
    const size_t numCurves = EC_get_builtin_curves(nullptr, 0);
    Vector<EC_builtin_curve> curves(numCurves);
    EC_get_builtin_curves(curves.begin(), numCurves);

    WTF::Vector<WTF::String> result;
    result.reserveInitialCapacity(numCurves);

    for (size_t i = 0; i < numCurves; i++) {
        const char* curveName = OBJ_nid2sn(curves[i].nid);
        result.append(WTF::String::fromUTF8(curveName));
    }

    return result;
}

WTF::Vector<WTF::String> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_getCiphers(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_getCiphers_Arguments&)
{
    ncrypto::MarkPopErrorOnReturn mark_pop_error_on_return;

    WTF::Vector<WTF::String> result;

    struct CipherPushContext {
        WTF::Vector<WTF::String>& result;
    };

    CipherPushContext ctx { result };

    auto callback = [](const EVP_CIPHER*, const char* name, const char*, void* arg) {
        auto* ctx = static_cast<CipherPushContext*>(arg);
        ctx->result.append(WTF::String::fromUTF8(name));
    };

    EVP_CIPHER_do_all_sorted(callback, &ctx);

    return result;
}

std::optional<bool> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_certVerifySpkac(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_certVerifySpkac_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.input) {
        return std::nullopt;
    }

    const auto& buffer = *args.input;
    if (buffer.empty()) {
        return false;
    }
    if (buffer.size() > std::numeric_limits<int32_t>().max()) {
        Bun::ERR::OUT_OF_RANGE(scope, lexicalGlobalObject, "spkac"_s, 0, std::numeric_limits<int32_t>().max(), jsNumber(buffer.size()));
        return std::nullopt;
    }

    return ncrypto::VerifySpkac(reinterpret_cast<const char*>(buffer.unsafePtr("The entry frame holds the SPKAC lease through synchronous OpenSSL parsing"_s)), buffer.size());
}

WTF::String Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_certExportPublicKey(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_certExportPublicKey_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.input) {
        return WTF::emptyString();
    }

    const auto& buffer = *args.input;
    if (buffer.empty()) {
        return WTF::emptyString();
    }
    if (buffer.size() > std::numeric_limits<int32_t>().max()) {
        Bun::ERR::OUT_OF_RANGE(scope, lexicalGlobalObject, "spkac"_s, 0, std::numeric_limits<int32_t>().max(), jsNumber(buffer.size()));
        return {};
    }

    auto bio = ncrypto::ExportPublicKey(reinterpret_cast<const char*>(buffer.unsafePtr("The entry frame holds the SPKAC lease through synchronous OpenSSL parsing"_s)), buffer.size());
    if (!bio) {
        return WTF::emptyString();
    }

    char* data = nullptr;
    long len = BIO_get_mem_data(bio.get(), &data);
    if (len <= 0 || data == nullptr) {
        return WTF::emptyString();
    }

    return String::fromUTF8({ data, static_cast<size_t>(len) });
}

Bindgen::NodeCryptoCertificateChallengeResult Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_certExportChallenge(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_certExportChallenge_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto emptyResult = [] {
        Bindgen::NodeCryptoCertificateChallengeResult result;
        result.set_empty_string(WTF::emptyString());
        return result;
    };

    if (!args.input) {
        return emptyResult();
    }

    const auto& buffer = *args.input;
    if (buffer.empty()) {
        return emptyResult();
    }
    if (buffer.size() > std::numeric_limits<int32_t>().max()) {
        Bun::ERR::OUT_OF_RANGE(scope, lexicalGlobalObject, "spkac"_s, 0, std::numeric_limits<int32_t>().max(), jsNumber(buffer.size()));
        return emptyResult();
    }

    auto cert = ncrypto::ExportChallenge(reinterpret_cast<const char*>(buffer.unsafePtr("The entry frame holds the SPKAC lease through synchronous OpenSSL parsing"_s)), buffer.size());
    if (!cert.data || cert.len == 0) {
        return emptyResult();
    }

    WTF::Vector<uint8_t> bytes;
    if (!bytes.tryGrow(cert.len)) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return emptyResult();
    }
    memcpy(bytes.mutableSpan().data(), cert.data, cert.len);
    Bindgen::NodeCryptoCertificateChallengeResult result;
    result.set_buffer(WTF::move(bytes));
    return result;
}

// From node.js
// https://github.com/nodejs/node/blob/5d9b63dbd4049f61657e3cff8b7ad1b6fa54ea26/src/crypto/crypto_cipher.cc#L41
std::optional<Bindgen::NodeCryptoCipherInfoResult> Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_getCipherInfo(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_getCipherInfo_Arguments& args)
{
    const auto& nameOrNid = args.nameOrNid;
    std::optional<int32_t> keyLengthOpt;
    std::optional<int32_t> ivLengthOpt;
    if (args.options) {
        keyLengthOpt = args.options->key_length;
        ivLengthOpt = args.options->iv_length;
    }

    const ncrypto::Cipher cipher = [&] {
        if (nameOrNid.is_integer()) {
            return ncrypto::Cipher::FromNid(nameOrNid.integer());
        }
        return ncrypto::Cipher::FromName(nameOrNid.string());
    }();

    if (!cipher) {
        return std::nullopt;
    }

    int32_t keyLength = cipher.getKeyLength();
    int32_t ivLength = cipher.getIvLength();
    int32_t blockSize = cipher.getBlockSize();
    ASCIILiteral modeLabel = cipher.getModeLabel();
    String name = cipher.getName();

    if (keyLengthOpt.has_value() || ivLengthOpt.has_value()) {
        auto ctx = ncrypto::CipherCtxPointer::New();
        if (!ctx.init(cipher, true)) {
            return std::nullopt;
        }

        if (keyLengthOpt.has_value()) {
            if (!ctx.setKeyLength(keyLengthOpt.value())) {
                return std::nullopt;
            }
            keyLength = keyLengthOpt.value();
        }

        if (ivLengthOpt.has_value()) {
            int32_t length = ivLengthOpt.value();
            if (cipher.isCcmMode()) {
                if (length < 7 || length > 13) {
                    return std::nullopt;
                }
            } else if (cipher.isGcmMode()) {
            } else if (cipher.isOcbMode()) {
                if (!ctx.setIvLength(length)) {
                    return std::nullopt;
                }
            } else {
                if (length != ivLength) {
                    return std::nullopt;
                }
            }
            ivLength = ivLengthOpt.value();
        }
    }

    Bindgen::NodeCryptoCipherInfoResult result {
        .name = name.convertToASCIILowercase(),
        .nid = cipher.getNid(),
        .key_length = keyLength,
    };

    if (!modeLabel.isEmpty()) {
        result.mode = String::fromUTF8(modeLabel);
    }

    if (!cipher.isStreamMode()) {
        result.block_size = blockSize;
    }

    if (ivLength != 0) {
        result.iv_length = ivLength;
    }

    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_hashConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_hashConstructor_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_JSHashClassStructure.constructor(globalObject);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanConstructor_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_JSDiffieHellmanClassStructure.constructor(globalObject);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_diffieHellmanGroupConstructor_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_JSDiffieHellmanGroupClassStructure.constructor(globalObject);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_cipherConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_cipherConstructor_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_JSCipherClassStructure.constructor(globalObject);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_keyObjectConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_keyObjectConstructor_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_JSKeyObjectClassStructure.constructor(globalObject);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_NodeCryptoBinding_x509CertificateConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeCryptoBinding_x509CertificateConstructor_Arguments&)
{
    auto* globalObject = static_cast<Zig::GlobalObject*>(&context.globalObject);
    return globalObject->m_JSX509CertificateClassStructure.constructor(globalObject);
}

} // namespace Bun
