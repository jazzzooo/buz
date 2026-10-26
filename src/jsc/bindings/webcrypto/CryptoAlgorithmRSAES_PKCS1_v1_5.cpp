/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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
#include "CryptoAlgorithmRSAES_PKCS1_v1_5.h"

#if ENABLE(WEB_CRYPTO)

#include "CryptoAlgorithmRsaKeyGenParams.h"
#include "CryptoKeyPair.h"
#include "CryptoKeyRSA.h"
#include <variant>

namespace WebCore {

static constexpr auto ALG = "RSA1_5"_s;

Ref<CryptoAlgorithm> CryptoAlgorithmRSAES_PKCS1_v1_5::create()
{
    return adoptRef(*new CryptoAlgorithmRSAES_PKCS1_v1_5);
}

CryptoAlgorithmIdentifier CryptoAlgorithmRSAES_PKCS1_v1_5::identifier() const
{
    return s_identifier;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmRSAES_PKCS1_v1_5::encrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&& key, Vector<uint8_t>&& plainText)
{
    if (key->type() != CryptoKeyType::Public) {
        return Exception { InvalidAccessError, ""_s };
    }

    return platformEncrypt(downcast<CryptoKeyRSA>(key.get()), plainText);
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmRSAES_PKCS1_v1_5::decrypt(const CryptoAlgorithmParameters&, Ref<CryptoKey>&& key, Vector<uint8_t>&& cipherText)
{
    if (key->type() != CryptoKeyType::Private) {
        return Exception { InvalidAccessError, ""_s };
    }

    return platformDecrypt(downcast<CryptoKeyRSA>(key.get()), cipherText);
}

ExceptionOr<KeyOrKeyPair> CryptoAlgorithmRSAES_PKCS1_v1_5::generateKey(const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    const auto& rsaParameters = downcast<CryptoAlgorithmRsaKeyGenParams>(parameters);

    if (usages & (CryptoKeyUsageSign | CryptoKeyUsageVerify | CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey)) {
        return Exception { SyntaxError, ""_s };
    }

    auto generated = CryptoKeyRSA::generatePair(CryptoAlgorithmIdentifier::RSAES_PKCS1_v1_5, CryptoAlgorithmIdentifier::SHA_1, false, rsaParameters.modulusLength, rsaParameters.publicExponentVector(), extractable, usages);
    if (generated.hasException()) return generated.releaseException();
    auto pair = generated.releaseReturnValue();
    pair.publicKey->setUsagesBitmap(pair.publicKey->usagesBitmap() & CryptoKeyUsageEncrypt);
    pair.privateKey->setUsagesBitmap(pair.privateKey->usagesBitmap() & CryptoKeyUsageDecrypt);
    return KeyOrKeyPair { WTF::move(pair) };
}

ExceptionOr<Ref<CryptoKey>> CryptoAlgorithmRSAES_PKCS1_v1_5::importKey(CryptoKeyFormat format, KeyData&& data, const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    RefPtr<CryptoKeyRSA> result;
    switch (format) {
    case CryptoKeyFormat::Jwk: {
        JsonWebKey key = WTF::move(std::get<JsonWebKey>(data));
        if (usages && ((!key.d.isNull() && (usages ^ CryptoKeyUsageDecrypt)) || (key.d.isNull() && (usages ^ CryptoKeyUsageEncrypt)))) {
            return Exception { SyntaxError, ""_s };
        }
        if (usages && !key.use.isNull() && key.use != "enc"_s) {
            return Exception { DataError, ""_s };
        }
        if (!key.alg.isNull() && key.alg != ALG) {
            return Exception { DataError, ""_s };
        }
        result = CryptoKeyRSA::importJwk(parameters.identifier, std::nullopt, WTF::move(key), extractable, usages);
        break;
    }
    case CryptoKeyFormat::Spki: {
        if (usages && (usages ^ CryptoKeyUsageEncrypt)) {
            return Exception { SyntaxError, ""_s };
        }
        result = CryptoKeyRSA::importSpki(parameters.identifier, std::nullopt, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    }
    case CryptoKeyFormat::Pkcs8: {
        if (usages && (usages ^ CryptoKeyUsageDecrypt)) {
            return Exception { SyntaxError, ""_s };
        }
        result = CryptoKeyRSA::importPkcs8(parameters.identifier, std::nullopt, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    }
    default:
        return Exception { NotSupportedError, ""_s };
    }
    if (!result) {
        return Exception { DataError, ""_s };
    }

    return Ref<CryptoKey> { *result };
}

ExceptionOr<KeyData> CryptoAlgorithmRSAES_PKCS1_v1_5::exportKey(CryptoKeyFormat format, Ref<CryptoKey>&& key)
{
    const auto& rsaKey = downcast<CryptoKeyRSA>(key.get());

    if (!rsaKey.keySizeInBits()) {
        return Exception { OperationError, ""_s };
    }

    KeyData result;
    switch (format) {
    case CryptoKeyFormat::Jwk: {
        JsonWebKey jwk = rsaKey.exportJwk();
        jwk.alg = String(ALG);
        result = WTF::move(jwk);
        break;
    }
    case CryptoKeyFormat::Spki: {
        auto spki = rsaKey.exportSpki();
        if (spki.hasException()) {
            return Exception { spki.releaseException().code(), ""_s };
        }
        result = spki.releaseReturnValue();
        break;
    }
    case CryptoKeyFormat::Pkcs8: {
        auto pkcs8 = rsaKey.exportPkcs8();
        if (pkcs8.hasException()) {
            return Exception { pkcs8.releaseException().code(), ""_s };
        }
        result = pkcs8.releaseReturnValue();
        break;
    }
    default:
        return Exception { NotSupportedError, ""_s };
    }

    return WTF::move(result);
}

}

#endif // ENABLE(WEB_CRYPTO)
