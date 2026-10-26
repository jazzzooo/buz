#include "CryptoGenNidKeyPair.h"

using namespace Bun;

ncrypto::EVPKeyCtxPointer NidKeyPairJobCtx::setup()
{
    ncrypto::EVPKeyCtxPointer ctx = ncrypto::EVPKeyCtxPointer::NewFromID(m_id);
    if (!ctx.initForKeygen()) {
        return {};
    }
    return ctx;
}
