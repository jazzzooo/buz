#pragma once

#include "ncrypto.h"
#include <expected>
#include <wtf/Vector.h>

namespace Bun {

enum class DSASigEnc {
    DER,
    P1363,
    Invalid,
};

enum class SignatureConversionResult { converted,
    invalid,
    out_of_memory };
SignatureConversionResult convertP1363ToDER(const ncrypto::Buffer<const unsigned char>&, const ncrypto::EVPKeyPointer&, WTF::Vector<uint8_t>&);

struct SignatureError {
    enum class Code {
        notInitialized,
        digestCreation,
        digestInitialization,
        digestUpdate,
        dsaParameters,
        digestFinalization,
        signInitialization,
        verifyInitialization,
        signatureDigest,
        rsaPadding,
        signatureAllocation,
        signing,
        p1363Allocation,
        p1363Conversion,
        outOfMemory,
    };
    Code code;
    uint32_t cryptoCode { 0 };
};

class StreamingSignature {
public:
    template<typename T> using Result = std::expected<T, SignatureError>;

    bool initialized() const { return !!m_digest; }
    Result<void> init(const EVP_MD*);
    Result<void> update(std::span<const uint8_t>);
    Result<WTF::Vector<uint8_t>> sign(const ncrypto::EVPKeyPointer&, DSASigEnc, int padding, std::optional<int> saltLength);
    Result<bool> verify(const ncrypto::EVPKeyPointer&, DSASigEnc, int padding, std::optional<int> saltLength, std::span<const uint8_t> signature);

private:
    struct Prepared {
        ncrypto::DataPointer digest;
        ncrypto::EVPKeyCtxPointer context;
    };

    Result<Prepared> prepare(const ncrypto::EVPKeyPointer&, bool signing, int padding, std::optional<int> saltLength);
    ncrypto::EVPMDCtxPointer m_digest;
};

}
