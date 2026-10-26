#include "CryptoGenDhKeyPair.h"

using namespace Bun;

ncrypto::EVPKeyCtxPointer DhKeyPairJobCtx::setup()
{
    ncrypto::EVPKeyPointer keyParams;

    if (ncrypto::DHPointer* group = std::get_if<ncrypto::DHPointer>(&m_prime)) {
        keyParams = ncrypto::EVPKeyPointer::NewDH(WTF::move(*group));
    } else if (ncrypto::BignumPointer* primeFixedValue = std::get_if<ncrypto::BignumPointer>(&m_prime)) {
        auto prime = primeFixedValue->clone();
        auto bnG = ncrypto::BignumPointer::New();
        if (!prime || !bnG || !bnG.setWord(m_generator)) {
            return {};
        }
        auto dh = ncrypto::DHPointer::New(WTF::move(prime), WTF::move(bnG));
        if (!dh) {
            return {};
        }

        keyParams = ncrypto::EVPKeyPointer::NewDH(WTF::move(dh));
    } else if (std::get_if<int>(&m_prime)) {
        auto paramCtx = ncrypto::EVPKeyCtxPointer::NewFromID(EVP_PKEY_DH);

        int* primeLength = std::get_if<int>(&m_prime);
        if (!paramCtx.initForParamgen() || !paramCtx.setDhParameters(*primeLength, m_generator)) {
            return {};
        }

        keyParams = paramCtx.paramgen();
    }

    if (!keyParams) {
        return {};
    }

    ncrypto::EVPKeyCtxPointer ctx = keyParams.newCtx();
    if (!ctx.initForKeygen()) {
        return {};
    }

    return ctx;
}
