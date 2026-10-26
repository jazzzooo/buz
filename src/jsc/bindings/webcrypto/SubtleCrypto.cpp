/*
 * Copyright (C) 2016-2019 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "SubtleCrypto.h"

#if ENABLE(WEB_CRYPTO)

#include "CryptoAlgorithm.h"
#include "CryptoKey.h"
#include "CryptoAlgorithmRegistry.h"

namespace WebCore {

static CryptoKeyUsageBitmap toCryptoKeyUsageBitmap(CryptoKeyUsage usage)
{
    switch (usage) {
    case CryptoKeyUsage::Encrypt:
        return CryptoKeyUsageEncrypt;
    case CryptoKeyUsage::Decrypt:
        return CryptoKeyUsageDecrypt;
    case CryptoKeyUsage::Sign:
        return CryptoKeyUsageSign;
    case CryptoKeyUsage::Verify:
        return CryptoKeyUsageVerify;
    case CryptoKeyUsage::DeriveKey:
        return CryptoKeyUsageDeriveKey;
    case CryptoKeyUsage::DeriveBits:
        return CryptoKeyUsageDeriveBits;
    case CryptoKeyUsage::WrapKey:
        return CryptoKeyUsageWrapKey;
    case CryptoKeyUsage::UnwrapKey:
        return CryptoKeyUsageUnwrapKey;
    }

    RELEASE_ASSERT_NOT_REACHED();
}

static CryptoKeyUsageBitmap toCryptoKeyUsageBitmap(const Vector<CryptoKeyUsage>& usages)
{
    CryptoKeyUsageBitmap result = 0;
    for (auto usage : usages)
        result |= toCryptoKeyUsageBitmap(usage);

    return result;
}

static void normalizeJsonWebKey(JsonWebKey& webKey)
{
    webKey.usages = webKey.key_ops ? toCryptoKeyUsageBitmap(webKey.key_ops.value()) : 0;
}

static ExceptionOr<KeyData> toKeyData(SubtleCrypto::KeyFormat format, SubtleCrypto::KeyDataVariant&& data)
{
    if ((format == SubtleCrypto::KeyFormat::Jwk) != std::holds_alternative<JsonWebKey>(data))
        return Exception { TypeError };
    if (auto* key = std::get_if<JsonWebKey>(&data))
        normalizeJsonWebKey(*key);
    return WTF::move(data);
}

static bool isSupportedExportKey(CryptoAlgorithmIdentifier identifier)
{
    switch (identifier) {
    case CryptoAlgorithmIdentifier::RSAES_PKCS1_v1_5:
        return false;
    case CryptoAlgorithmIdentifier::RSASSA_PKCS1_v1_5:
    case CryptoAlgorithmIdentifier::RSA_PSS:
    case CryptoAlgorithmIdentifier::RSA_OAEP:
    case CryptoAlgorithmIdentifier::AES_CTR:
    case CryptoAlgorithmIdentifier::AES_CBC:
    case CryptoAlgorithmIdentifier::AES_GCM:
    case CryptoAlgorithmIdentifier::AES_CFB:
    case CryptoAlgorithmIdentifier::AES_KW:
    case CryptoAlgorithmIdentifier::HMAC:
    case CryptoAlgorithmIdentifier::ECDSA:
    case CryptoAlgorithmIdentifier::ECDH:
    case CryptoAlgorithmIdentifier::Ed25519:
    case CryptoAlgorithmIdentifier::X25519:
        return true;
    default:
        return false;
    }
}

ExceptionOr<Vector<uint8_t>> SubtleCrypto::encrypt(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, Vector<uint8_t>&& data)
{
    if (params.identifier != key->algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s };
    if (!key->allows(CryptoKeyUsageEncrypt))
        return Exception { InvalidAccessError, "CryptoKey doesn't support encryption"_s };
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm)
        return Exception { NotSupportedError };
    return algorithm->encrypt(params, WTF::move(key), WTF::move(data));
}

ExceptionOr<Vector<uint8_t>> SubtleCrypto::decrypt(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, Vector<uint8_t>&& data)
{
    if (params.identifier != key->algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s };
    if (!key->allows(CryptoKeyUsageDecrypt))
        return Exception { InvalidAccessError, "CryptoKey doesn't support decryption"_s };
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm)
        return Exception { NotSupportedError };
    return algorithm->decrypt(params, WTF::move(key), WTF::move(data));
}

ExceptionOr<Vector<uint8_t>> SubtleCrypto::sign(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, Vector<uint8_t>&& data)
{
    if (params.identifier != key->algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s };
    if (!key->allows(CryptoKeyUsageSign))
        return Exception { InvalidAccessError, "CryptoKey doesn't support signing"_s };
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm)
        return Exception { NotSupportedError };
    return algorithm->sign(params, WTF::move(key), WTF::move(data));
}

ExceptionOr<bool> SubtleCrypto::verify(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, Vector<uint8_t>&& signature, Vector<uint8_t>&& data)
{
    if (params.identifier != key->algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s };
    if (!key->allows(CryptoKeyUsageVerify))
        return Exception { InvalidAccessError, "CryptoKey doesn't support verification"_s };
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm)
        return Exception { NotSupportedError };
    return algorithm->verify(params, WTF::move(key), WTF::move(signature), WTF::move(data));
}

ExceptionOr<KeyOrKeyPair> SubtleCrypto::generateKey(const CryptoAlgorithmParameters& params, bool extractable, Vector<CryptoKeyUsage>&& keyUsages)
{
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm) return Exception { NotSupportedError };
    auto result = algorithm->generateKey(params, extractable, toCryptoKeyUsageBitmap(keyUsages));
    if (result.hasException()) return result.releaseException();
    auto value = result.releaseReturnValue();
    if (auto* key = std::get_if<RefPtr<CryptoKey>>(&value)) {
        RELEASE_ASSERT(*key);
        if (((*key)->type() == CryptoKeyType::Private || (*key)->type() == CryptoKeyType::Secret) && !(*key)->usagesBitmap())
            return Exception { SyntaxError };
    } else if (!std::get<CryptoKeyPair>(value).privateKey->usagesBitmap()) {
        return Exception { SyntaxError };
    }
    return value;
}

ExceptionOr<Ref<CryptoKey>> SubtleCrypto::deriveKey(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& baseKey, const CryptoAlgorithmParameters& importParams, const CryptoAlgorithmParameters& lengthParams, bool extractable, Vector<CryptoKeyUsage>&& keyUsages)
{
    if (params.identifier != baseKey->algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s };
    if (!baseKey->allows(CryptoKeyUsageDeriveKey))
        return Exception { InvalidAccessError, "CryptoKey doesn't support CryptoKey derivation"_s };
    auto lengthAlgorithm = CryptoAlgorithmRegistry::create(lengthParams.identifier);
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!lengthAlgorithm || !algorithm) return Exception { NotSupportedError };
    auto length = lengthAlgorithm->getKeyLength(lengthParams);
    if (length.hasException())
        return Exception { length.releaseException().code(), "Cannot get key length from derivedKeyType"_s };
    auto data = algorithm->deriveBits(params, WTF::move(baseKey), length.releaseReturnValue());
    if (data.hasException()) return data.releaseException();
    return importKey(KeyFormat::Raw, KeyData { data.releaseReturnValue() }, importParams, extractable, WTF::move(keyUsages));
}

ExceptionOr<Vector<uint8_t>> SubtleCrypto::deriveBits(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, unsigned length)
{
    if (params.identifier != key->algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match AlgorithmIdentifier"_s };
    if (!key->allows(CryptoKeyUsageDeriveBits))
        return Exception { InvalidAccessError, "CryptoKey doesn't support bits derivation"_s };
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm)
        return Exception { NotSupportedError };
    return algorithm->deriveBits(params, WTF::move(key), length);
}

ExceptionOr<Ref<CryptoKey>> SubtleCrypto::importKey(KeyFormat format, KeyDataVariant&& input, const CryptoAlgorithmParameters& params, bool extractable, Vector<CryptoKeyUsage>&& keyUsages)
{
    auto data = toKeyData(format, WTF::move(input));
    if (data.hasException())
        return data.releaseException();
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    auto result = algorithm->importKey(format, data.releaseReturnValue(), params, extractable, toCryptoKeyUsageBitmap(keyUsages));
    if (result.hasException())
        return result.releaseException();
    auto key = result.releaseReturnValue();
    if ((key->type() == CryptoKeyType::Private || key->type() == CryptoKeyType::Secret) && !key->usagesBitmap())
        return Exception { SyntaxError };
    return key;
}

ExceptionOr<KeyData> SubtleCrypto::exportKey(KeyFormat format, Ref<CryptoKey>&& key)
{
    if (!isSupportedExportKey(key->algorithmIdentifier()))
        return Exception { NotSupportedError };
    if (!key->extractable())
        return Exception { InvalidAccessError, "The CryptoKey is nonextractable"_s };
    auto algorithm = CryptoAlgorithmRegistry::create(key->algorithmIdentifier());
    if (!algorithm) return Exception { NotSupportedError };
    return algorithm->exportKey(format, WTF::move(key));
}

ExceptionOr<void> SubtleCrypto::validateWrappingKey(const CryptoAlgorithmParameters& params, const CryptoKey& key, bool unwrap)
{
    if (params.identifier != key.algorithmIdentifier())
        return Exception { InvalidAccessError, "CryptoKey doesn't match wrapping AlgorithmIdentifier"_s };
    if (!key.allows(unwrap ? CryptoKeyUsageUnwrapKey : CryptoKeyUsageWrapKey))
        return Exception { InvalidAccessError, "CryptoKey doesn't support the wrapping operation"_s };
    return {};
}

ExceptionOr<Vector<uint8_t>> SubtleCrypto::wrapKey(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, Vector<uint8_t>&& bytes)
{
    auto validation = validateWrappingKey(params, key, false);
    if (validation.hasException()) return validation.releaseException();
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm) return Exception { NotSupportedError };
    if (params.identifier == CryptoAlgorithmIdentifier::AES_KW)
        return algorithm->wrapKey(WTF::move(key), WTF::move(bytes));
    return algorithm->encrypt(params, WTF::move(key), WTF::move(bytes));
}

ExceptionOr<Vector<uint8_t>> SubtleCrypto::unwrapKey(const CryptoAlgorithmParameters& params, Ref<CryptoKey>&& key, Vector<uint8_t>&& bytes)
{
    auto validation = validateWrappingKey(params, key, true);
    if (validation.hasException()) return validation.releaseException();
    auto algorithm = CryptoAlgorithmRegistry::create(params.identifier);
    if (!algorithm) return Exception { NotSupportedError };
    if (params.identifier == CryptoAlgorithmIdentifier::AES_KW)
        return algorithm->unwrapKey(WTF::move(key), WTF::move(bytes));
    return algorithm->decrypt(params, WTF::move(key), WTF::move(bytes));
}

}

#endif
