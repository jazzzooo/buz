#include "config.h"
#include "CryptoKeySerialization.h"
#include "CryptoKeyAES.h"
#include "CryptoKeyEC.h"
#include "CryptoKeyHMAC.h"
#include "CryptoKeyOKP.h"
#include "CryptoKeyRSA.h"
#include "CryptoKeyRSAComponents.h"
#include "CryptoKeyRaw.h"
#include <array>

namespace WebCore {

using Bun::Bindgen::nativeAllocationFailure;

// Positions are persistent serialization tags, independent of the native enum.
static constexpr CryptoAlgorithmIdentifier algorithms[] = {
    CryptoAlgorithmIdentifier::None,
    CryptoAlgorithmIdentifier::RSAES_PKCS1_v1_5,
    CryptoAlgorithmIdentifier::RSASSA_PKCS1_v1_5,
    CryptoAlgorithmIdentifier::RSA_PSS,
    CryptoAlgorithmIdentifier::RSA_OAEP,
    CryptoAlgorithmIdentifier::ECDSA,
    CryptoAlgorithmIdentifier::ECDH,
    CryptoAlgorithmIdentifier::AES_CTR,
    CryptoAlgorithmIdentifier::AES_CBC,
    CryptoAlgorithmIdentifier::AES_GCM,
    CryptoAlgorithmIdentifier::AES_CFB,
    CryptoAlgorithmIdentifier::AES_KW,
    CryptoAlgorithmIdentifier::HMAC,
    CryptoAlgorithmIdentifier::SHA_1,
    CryptoAlgorithmIdentifier::SHA_224,
    CryptoAlgorithmIdentifier::SHA_256,
    CryptoAlgorithmIdentifier::SHA_384,
    CryptoAlgorithmIdentifier::SHA_512,
    CryptoAlgorithmIdentifier::HKDF,
    CryptoAlgorithmIdentifier::PBKDF2,
    CryptoAlgorithmIdentifier::Ed25519,
    CryptoAlgorithmIdentifier::X25519,
    CryptoAlgorithmIdentifier::SHA3_256,
    CryptoAlgorithmIdentifier::SHA3_384,
    CryptoAlgorithmIdentifier::SHA3_512,
};

static uint8_t algorithmTag(CryptoAlgorithmIdentifier algorithm)
{
    static_assert(std::size(algorithms) <= 256);
    for (size_t i = 0; i < std::size(algorithms); ++i) {
        if (algorithms[i] == algorithm)
            return static_cast<uint8_t>(i);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static bool isHash(CryptoAlgorithmIdentifier algorithm)
{
    switch (algorithm) {
    case CryptoAlgorithmIdentifier::SHA_1:
    case CryptoAlgorithmIdentifier::SHA_224:
    case CryptoAlgorithmIdentifier::SHA_256:
    case CryptoAlgorithmIdentifier::SHA_384:
    case CryptoAlgorithmIdentifier::SHA_512:
    case CryptoAlgorithmIdentifier::SHA3_256:
    case CryptoAlgorithmIdentifier::SHA3_384:
    case CryptoAlgorithmIdentifier::SHA3_512:
        return true;
    default:
        return false;
    }
}

Bun::Bindgen::NativeAllocationResult<std::optional<Vector<uint8_t>>> serializeCryptoKey(const CryptoKey& key)
{
    CryptoAlgorithmIdentifier hash = CryptoAlgorithmIdentifier::None;
    uint8_t curve = 0;
    Vector<uint8_t> data;
    switch (key.keyClass()) {
    case CryptoKeyClass::AES:
        if (!data.tryAppend(downcast<CryptoKeyAES>(key).key().span()))
            return nativeAllocationFailure();
        break;
    case CryptoKeyClass::HMAC:
        hash = downcast<CryptoKeyHMAC>(key).hashAlgorithmIdentifier();
        if (!data.tryAppend(downcast<CryptoKeyHMAC>(key).key().span()))
            return nativeAllocationFailure();
        break;
    case CryptoKeyClass::Raw:
        if (!data.tryAppend(downcast<CryptoKeyRaw>(key).key().span()))
            return nativeAllocationFailure();
        break;
    case CryptoKeyClass::RSA: {
        auto& rsa = downcast<CryptoKeyRSA>(key);
        rsa.isRestrictedToHash(hash);
        auto exported = key.type() == CryptoKeyType::Private ? rsa.exportPkcs8() : rsa.exportSpki();
        if (exported.hasException())
            return std::nullopt;
        data = exported.releaseReturnValue();
        break;
    }
    case CryptoKeyClass::EC: {
        auto& ec = downcast<CryptoKeyEC>(key);
        switch (ec.namedCurve()) {
        case CryptoKeyEC::NamedCurve::P256: curve = 1; break;
        case CryptoKeyEC::NamedCurve::P384: curve = 2; break;
        case CryptoKeyEC::NamedCurve::P521: curve = 3; break;
        }
        auto exported = key.type() == CryptoKeyType::Private ? ec.exportPkcs8() : ec.exportSpki();
        if (exported.hasException())
            return std::nullopt;
        data = exported.releaseReturnValue();
        break;
    }
    case CryptoKeyClass::OKP: {
        auto& okp = downcast<CryptoKeyOKP>(key);
        auto exported = key.type() == CryptoKeyType::Private ? okp.exportPkcs8() : okp.exportSpki();
        if (exported.hasException())
            return std::nullopt;
        data = exported.releaseReturnValue();
        break;
    }
    }
    RELEASE_ASSERT(!(key.usagesBitmap() & ~0xff));
    // Version, algorithm, key type, extractability, usages, hash, curve, reserved.
    const std::array<uint8_t, 8> header {
        1, algorithmTag(key.algorithmIdentifier()), static_cast<uint8_t>(key.type()),
        static_cast<uint8_t>(key.extractable()), static_cast<uint8_t>(key.usagesBitmap()),
        algorithmTag(hash), curve, 0,
    };
    Vector<uint8_t> result;
    if (!result.tryAppend(std::span { header }) || !result.tryAppend(data.span()))
        return nativeAllocationFailure();
    return std::optional { WTF::move(result) };
}

Bun::Bindgen::NativeAllocationResult<RefPtr<CryptoKey>> deserializeCryptoKey(std::span<const uint8_t> bytes)
{
    if (bytes.size() < 8 || bytes[0] != 1 || bytes[1] >= std::size(algorithms)
        || bytes[2] > 2 || bytes[3] > 1 || bytes[5] >= std::size(algorithms) || bytes[7] != 0)
        return nullptr;
    auto algorithm = algorithms[bytes[1]];
    auto type = static_cast<CryptoKeyType>(bytes[2]);
    bool extractable = bytes[3];
    CryptoKeyUsageBitmap usages = bytes[4];
    auto hash = algorithms[bytes[5]];
    uint8_t curve = bytes[6];
    if (hash != CryptoAlgorithmIdentifier::None && !isHash(hash))
        return nullptr;
    Vector<uint8_t> data;
    if (!data.tryAppend(bytes.subspan(8)))
        return nativeAllocationFailure();
    RefPtr<CryptoKey> result;
    switch (algorithm) {
    case CryptoAlgorithmIdentifier::AES_CTR:
    case CryptoAlgorithmIdentifier::AES_CBC:
    case CryptoAlgorithmIdentifier::AES_GCM:
    case CryptoAlgorithmIdentifier::AES_CFB:
    case CryptoAlgorithmIdentifier::AES_KW:
        if (type != CryptoKeyType::Secret || hash != CryptoAlgorithmIdentifier::None || curve)
            return nullptr;
        result = CryptoKeyAES::importRaw(algorithm, WTF::move(data), extractable, usages);
        break;
    case CryptoAlgorithmIdentifier::HMAC:
        if (type != CryptoKeyType::Secret || !isHash(hash) || curve)
            return nullptr;
        result = CryptoKeyHMAC::importRaw(0, hash, WTF::move(data), extractable, usages);
        break;
    case CryptoAlgorithmIdentifier::HKDF:
    case CryptoAlgorithmIdentifier::PBKDF2:
        if (type != CryptoKeyType::Secret || extractable || hash != CryptoAlgorithmIdentifier::None || curve)
            return nullptr;
        result = CryptoKeyRaw::create(algorithm, WTF::move(data), usages);
        break;
    case CryptoAlgorithmIdentifier::RSAES_PKCS1_v1_5:
    case CryptoAlgorithmIdentifier::RSASSA_PKCS1_v1_5:
    case CryptoAlgorithmIdentifier::RSA_PSS:
    case CryptoAlgorithmIdentifier::RSA_OAEP: {
        if (type == CryptoKeyType::Secret || curve)
            return nullptr;
        auto optionalHash = hash == CryptoAlgorithmIdentifier::None ? std::nullopt : std::optional { hash };
        result = type == CryptoKeyType::Private
            ? CryptoKeyRSA::importPkcs8(algorithm, optionalHash, WTF::move(data), extractable, usages)
            : CryptoKeyRSA::importSpki(algorithm, optionalHash, WTF::move(data), extractable, usages);
        break;
    }
    case CryptoAlgorithmIdentifier::ECDH:
    case CryptoAlgorithmIdentifier::ECDSA: {
        if (type == CryptoKeyType::Secret || hash != CryptoAlgorithmIdentifier::None || curve < 1 || curve > 3)
            return nullptr;
        static constexpr ASCIILiteral curves[] = { "P-256"_s, "P-384"_s, "P-521"_s };
        result = type == CryptoKeyType::Private
            ? CryptoKeyEC::importPkcs8(algorithm, curves[curve - 1], WTF::move(data), extractable, usages)
            : CryptoKeyEC::importSpki(algorithm, curves[curve - 1], WTF::move(data), extractable, usages);
        break;
    }
    case CryptoAlgorithmIdentifier::Ed25519:
    case CryptoAlgorithmIdentifier::X25519: {
        if (type == CryptoKeyType::Secret || hash != CryptoAlgorithmIdentifier::None || curve)
            return nullptr;
        auto namedCurve = algorithm == CryptoAlgorithmIdentifier::Ed25519 ? CryptoKeyOKP::NamedCurve::Ed25519 : CryptoKeyOKP::NamedCurve::X25519;
        result = type == CryptoKeyType::Private
            ? CryptoKeyOKP::importPkcs8(algorithm, namedCurve, WTF::move(data), extractable, usages)
            : CryptoKeyOKP::importSpki(algorithm, namedCurve, WTF::move(data), extractable, usages);
        break;
    }
    default:
        return nullptr;
    }
    return result;
}

class LegacyKeyReader {
public:
    explicit LegacyKeyReader(std::span<const uint8_t> bytes)
        : m_bytes(bytes)
    {
    }

    bool byte(uint8_t& value)
    {
        if (m_bytes.empty())
            return false;
        value = m_bytes.front();
        m_bytes = m_bytes.subspan(1);
        return true;
    }

    bool integer(uint32_t& value)
    {
        if (m_bytes.size() < 4)
            return false;
        value = static_cast<uint32_t>(m_bytes[0]) | static_cast<uint32_t>(m_bytes[1]) << 8
            | static_cast<uint32_t>(m_bytes[2]) << 16 | static_cast<uint32_t>(m_bytes[3]) << 24;
        m_bytes = m_bytes.subspan(4);
        return true;
    }

    bool buffer(Vector<uint8_t>& value)
    {
        uint32_t length;
        if (!integer(length) || length > m_bytes.size())
            return false;
        if (!value.tryAppend(m_bytes.first(length))) {
            outOfMemory = true;
            return false;
        }
        m_bytes = m_bytes.subspan(length);
        return true;
    }

    bool algorithm(CryptoAlgorithmIdentifier& value)
    {
        static constexpr uint8_t tags[] = { 255, 0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 14, 15, 16, 17, 18, 20, 21, 22, 23, 24, 25, 26 };
        static_assert(std::size(tags) == std::size(algorithms));
        uint8_t tag;
        if (!byte(tag))
            return false;
        for (size_t i = 1; i < std::size(tags); ++i) {
            if (tags[i] == tag) {
                value = algorithms[i];
                return true;
            }
        }
        return false;
    }

    std::optional<ASCIILiteral> curve()
    {
        uint32_t length;
        if (!integer(length) || (length & 0x7fffffff) != 5)
            return std::nullopt;
        size_t stride = length & 0x80000000 ? 1 : 2;
        if (m_bytes.size() < 5 * stride)
            return std::nullopt;
        static constexpr ASCIILiteral curves[] = { "P-256"_s, "P-384"_s, "P-521"_s };
        for (auto curve : curves) {
            bool matches = true;
            for (size_t i = 0; i < 5; ++i) {
                if (m_bytes[i * stride] != curve.characters()[i] || (stride == 2 && m_bytes[i * stride + 1]))
                    matches = false;
            }
            if (matches) {
                m_bytes = m_bytes.subspan(5 * stride);
                return curve;
            }
        }
        return std::nullopt;
    }

    RefPtr<CryptoKey> key(uint32_t maximumVersion)
    {
        uint32_t version, keyVersion, extractable, count;
        if (!integer(version) || version > maximumVersion || !integer(keyVersion) || keyVersion > 1
            || !integer(extractable) || extractable > 1 || !integer(count) || count > 8)
            return nullptr;
        CryptoKeyUsageBitmap usages = 0;
        for (uint32_t i = 0; i < count; ++i) {
            uint8_t usage;
            if (!byte(usage) || usage > 7 || (usages & (1 << usage)))
                return nullptr;
            usages |= 1 << usage;
        }
        uint8_t kind;
        if (!byte(kind))
            return nullptr;
        CryptoAlgorithmIdentifier identifier, hash;
        Vector<uint8_t> data;
        switch (kind) {
        case 0:
            if (!buffer(data) || !algorithm(hash) || !isHash(hash))
                return nullptr;
            return CryptoKeyHMAC::importRaw(0, hash, WTF::move(data), extractable, usages);
        case 1:
            if (!algorithm(identifier) || !CryptoKeyAES::isValidAESAlgorithm(identifier) || !buffer(data))
                return nullptr;
            return CryptoKeyAES::importRaw(identifier, WTF::move(data), extractable, usages);
        case 2:
            return rsa(extractable, usages);
        case 3: {
            if (!algorithm(identifier) || !CryptoKeyEC::isValidECAlgorithm(identifier))
                return nullptr;
            auto namedCurve = curve();
            uint8_t type;
            if (!namedCurve || !byte(type) || type > 1 || !buffer(data))
                return nullptr;
            return type == 0
                ? CryptoKeyEC::importRaw(identifier, *namedCurve, WTF::move(data), extractable, usages)
                : CryptoKeyEC::importPkcs8(identifier, *namedCurve, WTF::move(data), extractable, usages);
        }
        case 4:
            if (!algorithm(identifier) || (identifier != CryptoAlgorithmIdentifier::HKDF && identifier != CryptoAlgorithmIdentifier::PBKDF2) || !buffer(data))
                return nullptr;
            return CryptoKeyRaw::create(identifier, WTF::move(data), usages);
        case 5: {
            uint8_t namedCurve;
            if (!algorithm(identifier) || !byte(namedCurve) || namedCurve > 1 || !buffer(data))
                return nullptr;
            auto curve = namedCurve == 0 ? CryptoKeyOKP::NamedCurve::X25519 : CryptoKeyOKP::NamedCurve::Ed25519;
            if (identifier != (namedCurve == 0 ? CryptoAlgorithmIdentifier::X25519 : CryptoAlgorithmIdentifier::Ed25519))
                return nullptr;
            // Version-one OKP records omit the key type; private-only usages disambiguate it.
            auto type = usages & (CryptoKeyUsageSign | CryptoKeyUsageDeriveKey | CryptoKeyUsageDeriveBits) ? CryptoKeyType::Private : CryptoKeyType::Public;
            return CryptoKeyOKP::create(identifier, curve, type, WTF::move(data), extractable, usages);
        }
        default:
            return nullptr;
        }
    }

    bool atEnd() const { return m_bytes.empty(); }
    bool outOfMemory = false;

private:
    RefPtr<CryptoKey> rsa(bool extractable, CryptoKeyUsageBitmap usages)
    {
        CryptoAlgorithmIdentifier identifier, hash = CryptoAlgorithmIdentifier::SHA_1;
        uint32_t restricted;
        uint8_t type;
        if (!algorithm(identifier) || !integer(restricted) || restricted > 1
            || (restricted && (!algorithm(hash) || !isHash(hash))) || !byte(type) || type > 1)
            return nullptr;
        switch (identifier) {
        case CryptoAlgorithmIdentifier::RSAES_PKCS1_v1_5:
        case CryptoAlgorithmIdentifier::RSASSA_PKCS1_v1_5:
        case CryptoAlgorithmIdentifier::RSA_PSS:
        case CryptoAlgorithmIdentifier::RSA_OAEP:
            break;
        default:
            return nullptr;
        }
        Vector<uint8_t> modulus, exponent, privateExponent;
        if (!buffer(modulus) || !buffer(exponent))
            return nullptr;
        std::unique_ptr<CryptoKeyRSAComponents> components;
        if (type == 0) {
            components = CryptoKeyRSAComponents::createPublic(WTF::move(modulus), WTF::move(exponent));
        } else {
            uint32_t primeCount;
            if (!buffer(privateExponent) || !integer(primeCount))
                return nullptr;
            if (primeCount == 0) {
                components = CryptoKeyRSAComponents::createPrivate(WTF::move(modulus), WTF::move(exponent), WTF::move(privateExponent));
            } else {
                if (primeCount < 2 || primeCount - 2 > m_bytes.size() / 12)
                    return nullptr;
                CryptoKeyRSAComponents::PrimeInfo first, second;
                if (!buffer(first.primeFactor) || !buffer(first.factorCRTExponent)
                    || !buffer(second.primeFactor) || !buffer(second.factorCRTExponent) || !buffer(second.factorCRTCoefficient))
                    return nullptr;
                Vector<CryptoKeyRSAComponents::PrimeInfo> others;
                if (!others.tryReserveInitialCapacity(primeCount - 2)) {
                    outOfMemory = true;
                    return nullptr;
                }
                for (uint32_t i = 2; i < primeCount; ++i) {
                    CryptoKeyRSAComponents::PrimeInfo prime;
                    if (!buffer(prime.primeFactor) || !buffer(prime.factorCRTExponent) || !buffer(prime.factorCRTCoefficient))
                        return nullptr;
                    others.unsafeAppendWithoutCapacityCheck(WTF::move(prime));
                }
                components = CryptoKeyRSAComponents::createPrivateWithAdditionalData(WTF::move(modulus), WTF::move(exponent), WTF::move(privateExponent), WTF::move(first), WTF::move(second), WTF::move(others));
            }
        }
        return CryptoKeyRSA::create(identifier, hash, restricted, *components, extractable, usages);
    }

    std::span<const uint8_t> m_bytes;
};

Bun::Bindgen::NativeAllocationResult<RefPtr<CryptoKey>> deserializeLegacyCryptoKey(std::span<const uint8_t> bytes, uint32_t maximumVersion)
{
    LegacyKeyReader reader(bytes);
    auto key = reader.key(maximumVersion);
    if (reader.outOfMemory)
        return nativeAllocationFailure();
    if (!reader.atEnd())
        return nullptr;
    return key;
}

}
