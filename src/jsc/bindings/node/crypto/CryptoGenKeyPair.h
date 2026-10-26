#pragma once

#include "root.h"
#include "ncrypto.h"
#include <wtf/FastMalloc.h>
#include <wtf/Vector.h>

namespace Bun {

struct KeyEncodingConfig {
    ncrypto::EVPKeyPointer::PublicKeyEncodingConfig publicKeyEncoding;
    ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig privateKeyEncoding;
};

struct KeyPairJobCtx {
public:
    KeyPairJobCtx(KeyEncodingConfig&& config)
        : m_publicKeyEncoding(config.publicKeyEncoding)
        , m_privateKeyEncoding(WTF::move(config.privateKeyEncoding))
    {
    }

    virtual ~KeyPairJobCtx() = default;

    void runTask();
    virtual ncrypto::EVPKeyCtxPointer setup() = 0;

    bool allocationFailed() const { return m_allocationFailed; }
    std::span<const uint32_t> errors() const { return m_errors.span(); }

    ncrypto::EVPKeyPointer::PublicKeyEncodingConfig m_publicKeyEncoding;
    ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig m_privateKeyEncoding;

    ncrypto::EVPKeyPointer m_key;

private:
    WTF::Vector<uint32_t> m_errors;
    bool m_hasRun { false };
    bool m_allocationFailed { false };
};

} // namespace Bun
