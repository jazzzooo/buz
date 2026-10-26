#include "CryptoGenEcKeyPair.h"

using namespace Bun;

ncrypto::EVPKeyCtxPointer EcKeyPairJobCtx::setup()
{
    ncrypto::EVPKeyCtxPointer keyCtx;
    switch (m_curveNid) {
    case EVP_PKEY_ED25519:
    case EVP_PKEY_ED448:
    case EVP_PKEY_X25519:
    case EVP_PKEY_X448:
        keyCtx = ncrypto::EVPKeyCtxPointer::NewFromID(m_curveNid);
        break;
    default: {
        auto paramCtx = ncrypto::EVPKeyCtxPointer::NewFromID(EVP_PKEY_EC);
        if (!paramCtx.initForParamgen() || !paramCtx.setEcParameters(m_curveNid, m_paramEncoding)) {
            return {};
        }

        auto keyParams = paramCtx.paramgen();
        if (!keyParams) {
            return {};
        }

        keyCtx = keyParams.newCtx();
    }
    }

    if (!keyCtx.initForKeygen()) {
        return {};
    }

    return keyCtx;
}
