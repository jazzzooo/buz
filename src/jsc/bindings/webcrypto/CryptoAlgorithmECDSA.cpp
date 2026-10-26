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
#include "CryptoAlgorithmECDSA.h"

#if ENABLE(WEB_CRYPTO)

#include "CryptoAlgorithmEcKeyParams.h"
#include "CryptoAlgorithmEcdsaParams.h"
#include "CryptoKeyEC.h"
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <wtf/CrossThreadCopier.h>

namespace WebCore {

namespace CryptoAlgorithmECDSAInternal {
static constexpr auto ALG256 = "ES256"_s;
static constexpr auto ALG384 = "ES384"_s;
static constexpr auto ALG512 = "ES512"_s;
static constexpr auto P256 = "P-256"_s;
static constexpr auto P384 = "P-384"_s;
static constexpr auto P521 = "P-521"_s;
}

Ref<CryptoAlgorithm> CryptoAlgorithmECDSA::create()
{
    return adoptRef(*new CryptoAlgorithmECDSA);
}

CryptoAlgorithmIdentifier CryptoAlgorithmECDSA::identifier() const
{
    return s_identifier;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmECDSA::sign(const CryptoAlgorithmParameters& parameters, Ref<CryptoKey>&& key, Vector<uint8_t>&& data)
{
    if (key->type() != CryptoKeyType::Private) {
        return Exception { InvalidAccessError, ""_s };
    }

    const auto& operation_parameters = downcast<CryptoAlgorithmEcdsaParams>(parameters);
    return platformSign(operation_parameters, downcast<CryptoKeyEC>(key.get()), data);
}

ExceptionOr<bool> CryptoAlgorithmECDSA::verify(const CryptoAlgorithmParameters& parameters, Ref<CryptoKey>&& key, Vector<uint8_t>&& signature, Vector<uint8_t>&& data)
{
    if (key->type() != CryptoKeyType::Public) {
        return Exception { InvalidAccessError, ""_s };
    }

    const auto& operation_parameters = downcast<CryptoAlgorithmEcdsaParams>(parameters);
    return platformVerify(operation_parameters, downcast<CryptoKeyEC>(key.get()), signature, data);
}

ExceptionOr<KeyOrKeyPair> CryptoAlgorithmECDSA::generateKey(const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    const auto& ecParameters = downcast<CryptoAlgorithmEcKeyParams>(parameters);

    if (usages & (CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt | CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey)) {
        return Exception { SyntaxError, ""_s };
    }

    auto result = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDSA, ecParameters.namedCurve, extractable, usages);
    if (result.hasException()) {
        return Exception { result.releaseException().code(), ""_s };
    }

    auto pair = result.releaseReturnValue();
    pair.publicKey->setUsagesBitmap(pair.publicKey->usagesBitmap() & CryptoKeyUsageVerify);
    pair.privateKey->setUsagesBitmap(pair.privateKey->usagesBitmap() & CryptoKeyUsageSign);
    return KeyOrKeyPair { WTF::move(pair) };
}

ExceptionOr<Ref<CryptoKey>> CryptoAlgorithmECDSA::importKey(CryptoKeyFormat format, KeyData&& data, const CryptoAlgorithmParameters& parameters, bool extractable, CryptoKeyUsageBitmap usages)
{
    using namespace CryptoAlgorithmECDSAInternal;
    const auto& ecParameters = downcast<CryptoAlgorithmEcKeyParams>(parameters);

    RefPtr<CryptoKeyEC> result;
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
        if (key.crv == P256)
            isMatched = key.alg.isNull() || key.alg == ALG256;
        if (key.crv == P384)
            isMatched = key.alg.isNull() || key.alg == ALG384;
        if (key.crv == P521)
            isMatched = key.alg.isNull() || key.alg == ALG512;
        if (!isMatched) {
            return Exception { DataError, ""_s };
        }

        result = CryptoKeyEC::importJwk(ecParameters.identifier, ecParameters.namedCurve, WTF::move(key), extractable, usages);
        break;
    }
    case CryptoKeyFormat::Raw:
        if (usages && (usages ^ CryptoKeyUsageVerify)) {
            return Exception { SyntaxError, ""_s };
        }
        result = CryptoKeyEC::importRaw(ecParameters.identifier, ecParameters.namedCurve, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    case CryptoKeyFormat::Spki:
        if (usages && (usages ^ CryptoKeyUsageVerify)) {
            return Exception { SyntaxError, ""_s };
        }
        result = CryptoKeyEC::importSpki(ecParameters.identifier, ecParameters.namedCurve, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    case CryptoKeyFormat::Pkcs8:
        if (usages && (usages ^ CryptoKeyUsageSign)) {
            return Exception { SyntaxError, ""_s };
        }
        result = CryptoKeyEC::importPkcs8(ecParameters.identifier, ecParameters.namedCurve, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    }
    if (!result) {
        return Exception { DataError, ""_s };
    }

    return Ref<CryptoKey> { *result };
}

ExceptionOr<KeyData> CryptoAlgorithmECDSA::exportKey(CryptoKeyFormat format, Ref<CryptoKey>&& key)
{
    const auto& ecKey = downcast<CryptoKeyEC>(key.get());

    if (!ecKey.keySizeInBits()) {
        return Exception { OperationError, ""_s };
    }

    KeyData result;
    switch (format) {
    case CryptoKeyFormat::Jwk: {
        auto jwk = ecKey.exportJwk();
        if (jwk.hasException()) {
            return Exception { jwk.releaseException().code(), ""_s };
        }
        result = jwk.releaseReturnValue();
        break;
    }
    case CryptoKeyFormat::Raw: {
        auto raw = ecKey.exportRaw();
        if (raw.hasException()) {
            return Exception { raw.releaseException().code(), ""_s };
        }
        result = raw.releaseReturnValue();
        break;
    }
    case CryptoKeyFormat::Spki: {
        auto spki = ecKey.exportSpki();
        if (spki.hasException()) {
            return Exception { spki.releaseException().code(), ""_s };
        }
        result = spki.releaseReturnValue();
        break;
    }
    case CryptoKeyFormat::Pkcs8: {
        auto pkcs8 = ecKey.exportPkcs8();
        if (pkcs8.hasException()) {
            return Exception { pkcs8.releaseException().code(), ""_s };
        }
        result = pkcs8.releaseReturnValue();
        break;
    }
    }

    return WTF::move(result);
}

} // namespace WebCore

#endif // ENABLE(WEB_CRYPTO)
