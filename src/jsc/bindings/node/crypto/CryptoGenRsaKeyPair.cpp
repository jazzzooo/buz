#include "CryptoGenRsaKeyPair.h"

using namespace Bun;

ncrypto::EVPKeyCtxPointer RsaKeyPairJobCtx::setup()
{
    ncrypto::EVPKeyCtxPointer ctx = ncrypto::EVPKeyCtxPointer::NewFromID(m_variant == RsaKeyVariant::RSA_PSS ? EVP_PKEY_RSA_PSS : EVP_PKEY_RSA);
    if (!ctx || !ctx.initForKeygen() || !ctx.setRsaKeygenBits(m_modulusLength)) {
        return {};
    }

    if (m_exponent != ncrypto::EVPKeyCtxPointer::kDefaultRsaExponent) {
        auto bn = ncrypto::BignumPointer::New();
        if (!bn.setWord(m_exponent) || !ctx.setRsaKeygenPubExp(WTF::move(bn))) {
            return {};
        }
    }

    if (m_variant == RsaKeyVariant::RSA_PSS) {
        if (m_md && !ctx.setRsaPssKeygenMd(m_md)) {
            return {};
        }

        auto& mgf1Md = m_mgfMd;
        if (!mgf1Md && m_md) {
            mgf1Md = m_md;
        }

        if (mgf1Md && !ctx.setRsaPssKeygenMgf1Md(mgf1Md)) {
            return {};
        }

        int saltLength = m_saltLength;
        if (saltLength < 0 && m_md) {
            saltLength = m_md.size();
        }

        if (saltLength >= 0 && !ctx.setRsaPssSaltlen(saltLength)) {
            return {};
        }
    }

    return ctx;
}
