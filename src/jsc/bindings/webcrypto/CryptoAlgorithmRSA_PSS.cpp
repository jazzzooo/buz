/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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
#include "CryptoAlgorithmRSA_PSS.h"

#if ENABLE(WEB_CRYPTO) && HAVE(RSA_PSS)

#include "CryptoAlgorithmRsaHashedImportParams.h"
#include "CryptoAlgorithmRsaHashedKeyGenParams.h"
#include "CryptoAlgorithmRsaPssParams.h"
#include "CryptoKeyPair.h"
#include "CryptoKeyRSA.h"
#include <variant>
#include <wtf/CrossThreadCopier.h>

namespace WebCore {

namespace CryptoAlgorithmRSA_PSSInternal {
static constexpr auto ALG1 = "PS1"_s;
static constexpr auto ALG224 = "PS224"_s;
static constexpr auto ALG256 = "PS256"_s;
static constexpr auto ALG384 = "PS384"_s;
static constexpr auto ALG512 = "PS512"_s;
}

Ref<CryptoAlgorithm> CryptoAlgorithmRSA_PSS::create()
{
    return adoptRef(*new CryptoAlgorithmRSA_PSS);
}

CryptoAlgorithmIdentifier CryptoAlgorithmRSA_PSS::identifier() const
{
    return s_identifier;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmRSA_PSS::sign(const CryptoAlgorithmParameters& parameters, Ref<CryptoKey>&& key, Vector<uint8_t>&& data)
{
    if (key->type() != CryptoKeyType::Private) {
        return Exception { InvalidAccessError, ""_s };
    }

    const auto& operation_parameters = downcast<CryptoAlgorithmRsaPssParams>(parameters);
    return platformSign(operation_parameters, downcast<CryptoKeyRSA>(key.get()), data);
}

ExceptionOr<bool> CryptoAlgorithmRSA_PSS::verify(const CryptoAlgorithmParameters& parameters, Ref<CryptoKey>&& key, Vector<uint8_t>&& signature, Vector<uint8_t>&& data)
{
    if (key->type() != CryptoKeyType::Public) {
        return Exception { InvalidAccessError, ""_s };
    }

    const auto& operation_parameters = downcast<CryptoAlgorithmRsaPssParams>(parameters);
    return platformVerify(operation_parameters, downcast<CryptoKeyRSA>(key.get()), signature, data);
}

ExceptionOr<KeyOrKeyPair> CryptoAlgorithmRSA_PSS::generateKey(const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    const auto& rsaParameters = downcast<CryptoAlgorithmRsaHashedKeyGenParams>(parameters);

    if (usages & (CryptoKeyUsageDecrypt | CryptoKeyUsageEncrypt | CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey)) {
        return Exception { SyntaxError, ""_s };
    }

    auto generated = CryptoKeyRSA::generatePair(CryptoAlgorithmIdentifier::RSA_PSS, rsaParameters.hashIdentifier, true, rsaParameters.modulusLength, rsaParameters.publicExponentVector(), extractable, usages);
    if (generated.hasException()) return generated.releaseException();
    auto pair = generated.releaseReturnValue();
    pair.publicKey->setUsagesBitmap(pair.publicKey->usagesBitmap() & CryptoKeyUsageVerify);
    pair.privateKey->setUsagesBitmap(pair.privateKey->usagesBitmap() & CryptoKeyUsageSign);
    return KeyOrKeyPair { WTF::move(pair) };
}

ExceptionOr<Ref<CryptoKey>> CryptoAlgorithmRSA_PSS::importKey(CryptoKeyFormat format, KeyData&& data, const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    using namespace CryptoAlgorithmRSA_PSSInternal;

    const auto& rsaParameters = downcast<CryptoAlgorithmRsaHashedImportParams>(parameters);

    RefPtr<CryptoKeyRSA> result;
    switch (format) {
    case CryptoKeyFormat::Jwk: {
        JsonWebKey key = WTF::move(std::get<JsonWebKey>(data));

        if (usages && ((!key.d.isNull() && (usages ^ CryptoKeyUsageSign)) || (key.d.isNull() && (usages ^ CryptoKeyUsageVerify)))) {
            return Exception { SyntaxError, ""_s };
        }
        if (usages && !key.use.isNull() && key.use != "sig"_s) {
            return Exception { DataError, ""_s };
        }

        bool isMatched = false;
        switch (rsaParameters.hashIdentifier) {
        case CryptoAlgorithmIdentifier::SHA_1:
            isMatched = key.alg.isNull() || key.alg == ALG1;
            break;
        case CryptoAlgorithmIdentifier::SHA_224:
            isMatched = key.alg.isNull() || key.alg == ALG224;
            break;
        case CryptoAlgorithmIdentifier::SHA_256:
            isMatched = key.alg.isNull() || key.alg == ALG256;
            break;
        case CryptoAlgorithmIdentifier::SHA_384:
            isMatched = key.alg.isNull() || key.alg == ALG384;
            break;
        case CryptoAlgorithmIdentifier::SHA_512:
            isMatched = key.alg.isNull() || key.alg == ALG512;
            break;
        case CryptoAlgorithmIdentifier::SHA3_256:
        case CryptoAlgorithmIdentifier::SHA3_384:
        case CryptoAlgorithmIdentifier::SHA3_512:
            isMatched = key.alg.isNull();
            break;
        default:
            break;
        }
        if (!isMatched) {
            return Exception { DataError, ""_s };
        }

        result = CryptoKeyRSA::importJwk(rsaParameters.identifier, rsaParameters.hashIdentifier, WTF::move(key), extractable, usages);
        break;
    }
    case CryptoKeyFormat::Spki: {
        if (usages && (usages ^ CryptoKeyUsageVerify)) {
            return Exception { SyntaxError, ""_s };
        }
        // FIXME: <webkit.org/b/165436>
        result = CryptoKeyRSA::importSpki(rsaParameters.identifier, rsaParameters.hashIdentifier, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    }
    case CryptoKeyFormat::Pkcs8: {
        if (usages && (usages ^ CryptoKeyUsageSign)) {
            return Exception { SyntaxError, ""_s };
        }
        // FIXME: <webkit.org/b/165436>
        result = CryptoKeyRSA::importPkcs8(parameters.identifier, rsaParameters.hashIdentifier, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
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

ExceptionOr<KeyData> CryptoAlgorithmRSA_PSS::exportKey(CryptoKeyFormat format, Ref<CryptoKey>&& key)
{
    using namespace CryptoAlgorithmRSA_PSSInternal;
    const auto& rsaKey = downcast<CryptoKeyRSA>(key.get());

    if (!rsaKey.keySizeInBits()) {
        return Exception { OperationError, ""_s };
    }

    KeyData result;
    switch (format) {
    case CryptoKeyFormat::Jwk: {
        JsonWebKey jwk = rsaKey.exportJwk();
        switch (rsaKey.hashAlgorithmIdentifier()) {
        case CryptoAlgorithmIdentifier::SHA_1:
            jwk.alg = String(ALG1);
            break;
        case CryptoAlgorithmIdentifier::SHA_224:
            jwk.alg = String(ALG224);
            break;
        case CryptoAlgorithmIdentifier::SHA_256:
            jwk.alg = String(ALG256);
            break;
        case CryptoAlgorithmIdentifier::SHA_384:
            jwk.alg = String(ALG384);
            break;
        case CryptoAlgorithmIdentifier::SHA_512:
            jwk.alg = String(ALG512);
            break;
        case CryptoAlgorithmIdentifier::SHA3_256:
        case CryptoAlgorithmIdentifier::SHA3_384:
        case CryptoAlgorithmIdentifier::SHA3_512:
            break;
        default:
            ASSERT_NOT_REACHED();
        }
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

#endif // ENABLE(WEB_CRYPTO) && HAVE(RSA_PSS)
