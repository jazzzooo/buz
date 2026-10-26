#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoGenKeyPair.h"

namespace Bun {

struct NidKeyPairJobCtx : KeyPairJobCtx {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(NidKeyPairJobCtx);

public:
    NidKeyPairJobCtx(int id, KeyEncodingConfig&& config)
        : KeyPairJobCtx(WTF::move(config))
        , m_id(id)
    {
    }

    ncrypto::EVPKeyCtxPointer setup() override;

    int m_id;
};

} // namespace Bun
