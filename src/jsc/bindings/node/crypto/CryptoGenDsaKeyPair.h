#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoGenKeyPair.h"

namespace Bun {

struct DsaKeyPairJobCtx : KeyPairJobCtx {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(DsaKeyPairJobCtx);

public:
    DsaKeyPairJobCtx(uint32_t modulusLength, std::optional<int32_t> divisorLength, KeyEncodingConfig&& config)
        : KeyPairJobCtx(WTF::move(config))
        , m_modulusLength(modulusLength)
        , m_divisorLength(divisorLength)
    {
    }

    ncrypto::EVPKeyCtxPointer setup() override;

    uint32_t m_modulusLength;
    std::optional<int32_t> m_divisorLength;
};

} // namespace Bun
