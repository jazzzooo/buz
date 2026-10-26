#pragma once

#include "ncrypto.h"
#include <expected>
#include <wtf/Vector.h>

namespace Bun {

struct ECDHError {
    enum class Code {
        outOfMemory,
        invalidCurve,
        createKey,
        generateKey,
        missingPublicKey,
        publicKeySize,
        encodePublicKey,
        missingPrivateKey,
        encodePrivateKey,
        invalidKeyPair,
        invalidPeerKey,
        computeSecret,
        decodePublicKey,
        setPublicKey,
        invalidPrivateKey,
        setPrivateKey,
        derivePublicKey,
        createGroup,
        convertPoint,
    };
    Code code;
    uint32_t cryptoCode { 0 };
};

class ECDHKey {
public:
    template<typename T> using Result = std::expected<T, ECDHError>;

    explicit ECDHKey(ncrypto::ECKeyPointer&& key)
        : m_key(WTF::move(key))
    {
        ASSERT(m_key.getGroup());
    }

    static Result<ncrypto::ECKeyPointer> create(const WTF::String& curve);
    Result<ncrypto::ECKeyPointer> generateCandidate() const;
    void commit(ncrypto::ECKeyPointer&& key) { m_key = WTF::move(key); }
    static Result<WTF::Vector<uint8_t>> publicKey(const ncrypto::ECKeyPointer&, point_conversion_form_t);
    Result<WTF::Vector<uint8_t>> publicKey(point_conversion_form_t form) const { return publicKey(m_key, form); }
    Result<WTF::Vector<uint8_t>> privateKey() const;
    Result<WTF::Vector<uint8_t>> computeSecret(std::span<const uint8_t>) const;
    Result<void> setPublicKey(std::span<const uint8_t>);
    Result<void> setPrivateKey(std::span<const uint8_t>);
    static Result<WTF::Vector<uint8_t>> convertKey(const WTF::String& curve, std::span<const uint8_t>, point_conversion_form_t);

private:
    ncrypto::ECKeyPointer m_key;
};

}
