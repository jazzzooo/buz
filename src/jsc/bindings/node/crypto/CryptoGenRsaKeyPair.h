#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoGenKeyPair.h"

namespace Bun {

enum class RsaKeyVariant {
    RSA_SSA_PKCS1_v1_5,
    RSA_PSS,
    RSA_OAEP,
};

struct RsaKeyPairJobCtx : KeyPairJobCtx {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(RsaKeyPairJobCtx);

public:
    RsaKeyPairJobCtx(RsaKeyVariant variant, uint32_t modulusLength, uint32_t exponent, KeyEncodingConfig&& encodingConfig)
        : KeyPairJobCtx(WTF::move(encodingConfig))
        , m_variant(variant)
        , m_modulusLength(modulusLength)
        , m_exponent(exponent)
    {
    }

    RsaKeyPairJobCtx(RsaKeyVariant variant, uint32_t modulusLength, uint32_t exponent, std::optional<int32_t> saltLength, ncrypto::Digest md, ncrypto::Digest mgfMd, KeyEncodingConfig&& encodingConfig)
        : KeyPairJobCtx(WTF::move(encodingConfig))
        , m_variant(variant)
        , m_modulusLength(modulusLength)
        , m_exponent(exponent)
        , m_saltLength(saltLength.value_or(-1))
        , m_md(md)
        , m_mgfMd(mgfMd)
    {
    }

    ncrypto::EVPKeyCtxPointer setup() override;

    RsaKeyVariant m_variant;
    uint32_t m_modulusLength;
    uint32_t m_exponent;

    int32_t m_saltLength { -1 };
    ncrypto::Digest m_md = nullptr;
    ncrypto::Digest m_mgfMd = nullptr;
};

} // namespace Bun
