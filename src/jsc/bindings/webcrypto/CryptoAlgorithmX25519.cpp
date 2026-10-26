/*
 * Copyright (C) 2023 Igalia S.L.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2,1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "CryptoAlgorithmX25519.h"

#if ENABLE(WEB_CRYPTO)

#include "CryptoAlgorithmEcdhKeyDeriveParams.h"
#include "CryptoKeyOKP.h"
#include "CryptoDigest.h"
#include <openssl/curve25519.h>
#include <wtf/CryptographicUtilities.h>

namespace WebCore {

Ref<CryptoAlgorithm> CryptoAlgorithmX25519::create()
{
    return adoptRef(*new CryptoAlgorithmX25519);
}

CryptoAlgorithmIdentifier CryptoAlgorithmX25519::identifier() const
{
    return s_identifier;
}

ExceptionOr<KeyOrKeyPair> CryptoAlgorithmX25519::generateKey(const CryptoAlgorithmParameters&, bool extractable, CryptoKeyUsageBitmap usages)
{
    if (usages & (CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt | CryptoKeyUsageSign | CryptoKeyUsageVerify | CryptoKeyUsageWrapKey | CryptoKeyUsageUnwrapKey)) {
        return Exception { ExceptionCode::SyntaxError, ""_s };
    }

    auto result = CryptoKeyOKP::generatePair(CryptoAlgorithmIdentifier::X25519, CryptoKeyOKP::NamedCurve::X25519, extractable, usages);
    if (result.hasException()) {
        return Exception { result.releaseException().code(), ""_s };
    }

    auto pair = result.releaseReturnValue();
    pair.publicKey->setUsagesBitmap(0);
    pair.privateKey->setUsagesBitmap(pair.privateKey->usagesBitmap() & (CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits));
    return KeyOrKeyPair { WTF::move(pair) };
}

#if !PLATFORM(COCOA) && !USE(GCRYPT)
ExceptionOr<Vector<uint8_t>> CryptoAlgorithmX25519::platformDeriveBits(const CryptoKeyOKP& baseKey, const CryptoKeyOKP& publicKey)
{
    Vector<uint8_t> result;
    if (!result.tryGrow(X25519_SHARED_KEY_LEN))
        return Exception { OutOfMemoryError };
    if (!X25519(result.begin(), baseKey.platformKey().begin(), publicKey.platformKey().begin()))
        return Exception { OperationError };
    return result;
}
#endif

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmX25519::deriveBits(const CryptoAlgorithmParameters& parameters, Ref<CryptoKey>&& baseKey, size_t length)
{
    if (baseKey->type() != CryptoKey::Type::Private) {
        return Exception { ExceptionCode::InvalidAccessError, ""_s };
    }
    auto& ecParameters = downcast<CryptoAlgorithmEcdhKeyDeriveParams>(parameters);
    ASSERT(ecParameters.publicKey);
    if (ecParameters.publicKey->type() != CryptoKey::Type::Public) {
        return Exception { ExceptionCode::InvalidAccessError, ""_s };
    }
    if (baseKey->algorithmIdentifier() != ecParameters.publicKey->algorithmIdentifier()) {
        return Exception { ExceptionCode::InvalidAccessError, ""_s };
    }
    auto& ecBaseKey = downcast<CryptoKeyOKP>(baseKey.get());
    auto& ecPublicKey = downcast<CryptoKeyOKP>(*(ecParameters.publicKey.get()));
    if (ecBaseKey.namedCurve() != ecPublicKey.namedCurve()) {
        return Exception { ExceptionCode::InvalidAccessError, ""_s };
    }

    const auto& operation_publicKey = ecParameters.publicKey;
    auto result = platformDeriveBits(downcast<CryptoKeyOKP>(baseKey.get()), downcast<CryptoKeyOKP>(*operation_publicKey));
    if (result.hasException())
        return result.releaseException();
    auto derivedKey = result.releaseReturnValue();
#if !HAVE(X25519_ZERO_CHECKS)
    // https://datatracker.ietf.org/doc/html/rfc7748#section-6.1
    constexpr auto expectedOutputSize = 32;
    constexpr std::array<uint8_t, expectedOutputSize> zeros {};
    if (derivedKey.size() != expectedOutputSize || !constantTimeMemcmp(derivedKey.span(), zeros))
        return Exception { OperationError };
#endif
    if (length) {
        auto lengthInBytes = length / 8 + (length % 8 != 0);
        if (lengthInBytes > derivedKey.size())
            return Exception { OperationError };
        derivedKey.shrink(lengthInBytes);
    }
    return derivedKey;
}

ExceptionOr<Ref<CryptoKey>> CryptoAlgorithmX25519::importKey(CryptoKeyFormat format, KeyData&& data, const CryptoAlgorithmParameters&, bool extractable, CryptoKeyUsageBitmap usages)
{
    RefPtr<CryptoKeyOKP> result;
    switch (format) {
    case CryptoKeyFormat::Jwk: {
        JsonWebKey key = WTF::move(std::get<JsonWebKey>(data));

        bool isUsagesAllowed = false;
        if (!key.d.isNull()) {
            isUsagesAllowed = isUsagesAllowed || !(usages ^ CryptoKeyUsageDeriveKey);
            isUsagesAllowed = isUsagesAllowed || !(usages ^ CryptoKeyUsageDeriveBits);
            isUsagesAllowed = isUsagesAllowed || !(usages ^ (CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits));
        }
        isUsagesAllowed = isUsagesAllowed || !usages;
        if (!isUsagesAllowed) {
            return Exception { ExceptionCode::SyntaxError, ""_s };
        }

        if (usages && !key.use.isNull() && key.use != "enc"_s) {
            return Exception { ExceptionCode::DataError, ""_s };
        }

        result = CryptoKeyOKP::importJwk(CryptoAlgorithmIdentifier::X25519, CryptoKeyOKP::NamedCurve::X25519, WTF::move(key), extractable, usages);
        break;
    }
    case CryptoKeyFormat::Raw:
        if (usages) {
            return Exception { ExceptionCode::SyntaxError, ""_s };
        }
        result = CryptoKeyOKP::importRaw(CryptoAlgorithmIdentifier::X25519, CryptoKeyOKP::NamedCurve::X25519, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    case CryptoKeyFormat::Spki:
        if (usages) {
            return Exception { ExceptionCode::SyntaxError, ""_s };
        }
        result = CryptoKeyOKP::importSpki(CryptoAlgorithmIdentifier::X25519, CryptoKeyOKP::NamedCurve::X25519, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    case CryptoKeyFormat::Pkcs8:
        if (usages && (usages ^ CryptoKeyUsageDeriveKey) && (usages ^ CryptoKeyUsageDeriveBits) && (usages ^ (CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits))) {
            return Exception { ExceptionCode::SyntaxError, ""_s };
        }
        result = CryptoKeyOKP::importPkcs8(CryptoAlgorithmIdentifier::X25519, CryptoKeyOKP::NamedCurve::X25519, WTF::move(std::get<Vector<uint8_t>>(data)), extractable, usages);
        break;
    }
    if (!result) {
        return Exception { ExceptionCode::DataError, ""_s };
    }

    return Ref<CryptoKey> { *result };
}

ExceptionOr<KeyData> CryptoAlgorithmX25519::exportKey(CryptoKeyFormat format, Ref<CryptoKey>&& key)
{
    const auto& ecKey = downcast<CryptoKeyOKP>(key.get());

    if (!ecKey.keySizeInBits()) {
        return Exception { ExceptionCode::OperationError, ""_s };
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
