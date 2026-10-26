#pragma once

#include "root.h"
#include "CryptoUtil.h"
#include "KeyObject.h"

namespace Bun {

namespace Bindgen {
class NodeCryptoAsymmetricKeyInput;
}

struct NodeCryptoSigningKey {
    RefPtr<KeyObjectData> keyData;
    std::optional<int32_t> padding;
    std::optional<int32_t> saltLength;
    DSASigEnc dsaSigEnc;
};

std::optional<NodeCryptoSigningKey> createNodeCryptoSigningKey(JSC::JSGlobalObject&, const Bindgen::NodeCryptoAsymmetricKeyInput&, bool verify);

struct SignJobCtx {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(SignJobCtx);

public:
    enum class Mode {
        Sign,
        Verify
    };

    static SignJobCtx* tryCreate(Mode, NodeCryptoSigningKey&&, std::span<const uint8_t>, ncrypto::Digest, std::span<const uint8_t> signature = {});

    void runTask();
    std::optional<WTF::Vector<uint8_t>> takeSignResult();
    std::optional<bool> takeVerifyResult();
    bool allocationFailed() const { return m_allocationFailed; }

    Mode m_mode;
    RefPtr<KeyObjectData> m_keyData;
    WTF::Vector<uint8_t> m_data;
    WTF::Vector<uint8_t> m_signature;
    ncrypto::Digest m_digest;
    std::optional<int32_t> m_padding;
    std::optional<int32_t> m_saltLength;
    DSASigEnc m_dsaSigEnc;
    bool m_valid { true };

    std::optional<WTF::Vector<uint8_t>> m_signResult;
    std::optional<bool> m_verifyResult;

private:
    SignJobCtx(Mode, NodeCryptoSigningKey&&, WTF::Vector<uint8_t>&&, ncrypto::Digest, WTF::Vector<uint8_t>&&, bool valid);
    bool m_hasRun { false };
    bool m_allocationFailed { false };
};

} // namespace Bun
