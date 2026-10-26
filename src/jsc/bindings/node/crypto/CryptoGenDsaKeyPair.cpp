#include "CryptoGenDsaKeyPair.h"

using namespace Bun;

ncrypto::EVPKeyCtxPointer DsaKeyPairJobCtx::setup()
{
    ncrypto::EVPKeyCtxPointer paramCtx = ncrypto::EVPKeyCtxPointer::NewFromID(EVP_PKEY_DSA);

    if (!paramCtx || !paramCtx.initForParamgen() || !paramCtx.setDsaParameters(m_modulusLength, m_divisorLength)) {
        return {};
    }

    auto keyParams = paramCtx.paramgen();
    if (!keyParams) {
        return {};
    }

    ncrypto::EVPKeyCtxPointer keyCtx = keyParams.newCtx();
    if (!keyCtx.initForKeygen()) {
        return {};
    }

    return keyCtx;
}
