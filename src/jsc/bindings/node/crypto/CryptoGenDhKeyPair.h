#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoGenKeyPair.h"

namespace Bun {

struct DhKeyPairJobCtx : KeyPairJobCtx {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(DhKeyPairJobCtx);

public:
    DhKeyPairJobCtx(ncrypto::DHPointer&& group, KeyEncodingConfig&& config)
        : KeyPairJobCtx(WTF::move(config))
        , m_prime(WTF::move(group))
    {
    }

    DhKeyPairJobCtx(int primeLength, uint32_t generator, KeyEncodingConfig&& config)
        : KeyPairJobCtx(WTF::move(config))
        , m_prime(primeLength)
        , m_generator(generator)
    {
    }

    DhKeyPairJobCtx(ncrypto::BignumPointer&& prime, uint32_t generator, KeyEncodingConfig&& config)
        : KeyPairJobCtx(WTF::move(config))
        , m_prime(WTF::move(prime))
        , m_generator(generator)
    {
    }

    ncrypto::EVPKeyCtxPointer setup() override;

    WTF::Variant<ncrypto::DHPointer, ncrypto::BignumPointer, int> m_prime;
    uint32_t m_generator { 0 };
};

} // namespace Bun
