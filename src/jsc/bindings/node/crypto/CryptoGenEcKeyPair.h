#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoGenKeyPair.h"

namespace Bun {

struct EcKeyPairJobCtx : KeyPairJobCtx {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(EcKeyPairJobCtx);

public:
    EcKeyPairJobCtx(int curveNid, int paramEncoding, KeyEncodingConfig&& config)
        : KeyPairJobCtx(WTF::move(config))
        , m_curveNid(curveNid)
        , m_paramEncoding(paramEncoding)
    {
    }

    ncrypto::EVPKeyCtxPointer setup() override;

    int m_curveNid;
    int m_paramEncoding;
};

} // namespace Bun
