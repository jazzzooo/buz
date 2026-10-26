#pragma once

#include "root.h"
#include "ncrypto.h"
#include "Bindgen/NativeResult.h"
#include <wtf/FastMalloc.h>

namespace Bun {

struct CheckPrimeJobCtx {
    CheckPrimeJobCtx(std::span<const uint8_t> candidate, int32_t checks);
    ~CheckPrimeJobCtx() = default;

    void runTask();
    Bindgen::NativeAllocationResult<std::optional<bool>> takeResult();

    int32_t m_checks;
    ncrypto::BignumPointer m_candidate;

    std::optional<bool> m_result;
    bool m_allocationFailed { false };

    void operator delete(void* allocation) { WTF::fastFree(allocation); }
};

enum class GeneratePrimeJobStatus : uint8_t {
    Success,
    InvalidAdd,
    InvalidRem,
    OperationFailed,
};

struct GeneratePrimeJobCtx {
    GeneratePrimeJobCtx(
        int32_t size,
        bool safe,
        std::optional<std::span<const uint8_t>> add,
        std::optional<std::span<const uint8_t>> rem);
    ~GeneratePrimeJobCtx() = default;

    GeneratePrimeJobStatus status() const;
    void runTask();
    Bindgen::NativeAllocationResult<std::optional<WTF::Vector<uint8_t>>> takeResult();

    int32_t m_size;
    bool m_safe;
    ncrypto::BignumPointer m_add;
    ncrypto::BignumPointer m_rem;
    ncrypto::BignumPointer m_prime;
    GeneratePrimeJobStatus m_status { GeneratePrimeJobStatus::Success };
    bool m_hasResult { false };
    bool m_allocationFailed { false };

    void operator delete(void* allocation) { WTF::fastFree(allocation); }
};

} // namespace Bun
