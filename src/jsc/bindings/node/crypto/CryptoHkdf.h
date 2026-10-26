#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoUtil.h"
#include "Bindgen/NativeResult.h"
#include <wtf/FastMalloc.h>

namespace Bun {

struct HkdfJobCtx {
    HkdfJobCtx(
        ncrypto::Digest digest,
        size_t length,
        WTF::Vector<uint8_t>&& key,
        WTF::Vector<uint8_t>&& info,
        WTF::Vector<uint8_t>&& salt);
    ~HkdfJobCtx();

    void runTask();
    Bindgen::NativeAllocationResult<std::optional<WTF::Vector<uint8_t>>> takeResult();

    ncrypto::Digest m_digest;
    size_t m_length;
    WTF::Vector<uint8_t> m_key;
    WTF::Vector<uint8_t> m_info;
    WTF::Vector<uint8_t> m_salt;
    std::optional<ByteSource> m_result;

    void operator delete(void* allocation) { WTF::fastFree(allocation); }
};

} // namespace Bun
