#pragma once

#include "root.h"
#include "KeyObjectData.h"

namespace Bun {

struct DhJobCtx {
    WTF_MAKE_TZONE_ALLOCATED(DhJobCtx);

public:
    DhJobCtx(KeyObjectData* privateKey, KeyObjectData* publicKey);
    ~DhJobCtx() = default;

    void runTask();
    std::optional<WTF::Vector<uint8_t>> takeResult();

    RefPtr<KeyObjectData> m_privateKey;
    RefPtr<KeyObjectData> m_publicKey;
    std::optional<WTF::Vector<uint8_t>> m_result;
};

} // namespace Bun
