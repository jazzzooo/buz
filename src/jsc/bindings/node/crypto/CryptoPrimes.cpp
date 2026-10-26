#include "CryptoPrimes.h"
#include "SchemaBindings.h"
#include "CryptoUtil.h"
#include <JavaScriptCore/JSBigInt.h>
#include <bit>

namespace Bun::Bindgen::Custom {

WTF::Vector<uint8_t> bunBindgenNodeCryptoUnsignedBigIntOrBuffer(
    JSC::JSGlobalObject& global,
    const Bun::Bindgen::NodeCryptoUnsignedBigIntOrBufferInput& input,
    WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    WTF::Vector<uint8_t> result;

    if (input.is_buffer()) {
        if (!result.tryAppend(input.buffer())) {
            JSC::throwOutOfMemoryError(&global, scope);
            return {};
        }
        scope.release();
        return result;
    }

    RELEASE_ASSERT(input.is_bigint());
    auto value = input.bigint();
#if USE(BIGINT32)
    if (value.isBigInt32()) {
        auto integer = value.bigInt32AsInt32();
        if (integer < 0) {
            Bun::ERR::OUT_OF_RANGE(scope, &global, name, ">= 0"_s, value);
            return {};
        }
        auto magnitude = static_cast<uint32_t>(integer);
        size_t byteLength = std::max<size_t>(1, (std::bit_width(magnitude) + 7) / 8);
        if (!result.tryGrow(byteLength)) {
            JSC::throwOutOfMemoryError(&global, scope);
            return {};
        }
        for (size_t index = 0; index < byteLength; ++index)
            result[byteLength - index - 1] = static_cast<uint8_t>(magnitude >> (index * 8));
        return result;
    }
#endif
    auto* bigInt = value.asHeapBigInt();
    if (bigInt->sign()) {
        Bun::ERR::OUT_OF_RANGE(scope, &global, name, ">= 0"_s, value);
        return {};
    }
    size_t byteLength = std::max<size_t>(1, (static_cast<size_t>(bigInt->bitLength()) + 7) / 8);
    if (!result.tryGrow(byteLength)) {
        JSC::throwOutOfMemoryError(&global, scope);
        return {};
    }
    if (bigInt->isZero())
        result[0] = 0;
    else {
        auto digits = std::as_const(*bigInt).digits();
        for (size_t index = 0; index < byteLength; ++index) {
            auto digit = digits[index / sizeof(JSC::JSBigInt::Digit)];
            auto shift = (index % sizeof(JSC::JSBigInt::Digit)) * 8;
            result[byteLength - index - 1] = static_cast<uint8_t>(digit >> shift);
        }
    }
    JSC::ensureStillAliveHere(value);
    scope.release();
    return result;
}

}

namespace Bun {

CheckPrimeJobCtx::CheckPrimeJobCtx(std::span<const uint8_t> candidate, int32_t checks)
    : m_checks(checks)
    , m_candidate(candidate.data(), candidate.size())
{
}

void CheckPrimeJobCtx::runTask()
{
    if (!m_candidate)
        return;

    ERR_clear_error();
    auto result = m_candidate.isPrime(m_checks);
    bool allocationFailed = ncrypto::takeAllocationFailure();
    m_allocationFailed = result < 0 && allocationFailed;
    if (result >= 0)
        m_result = result == 1;
}

Bindgen::NativeAllocationResult<std::optional<bool>> CheckPrimeJobCtx::takeResult()
{
    if (m_allocationFailed)
        return Bindgen::nativeAllocationFailure();
    auto result = m_result;
    m_result.reset();
    return result;
}

Bindgen::NativeAllocationResult<CheckPrimeJobCtx*> Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeCreate(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeCreate_Arguments& args)
{
    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(CheckPrimeJobCtx)).getValue(storage))
        return Bindgen::nativeAllocationFailure();
    ERR_clear_error();
    auto job = std::unique_ptr<CheckPrimeJobCtx>(new (NotNull, storage) CheckPrimeJobCtx(args.candidate, args.checks));
    bool allocationFailed = ncrypto::takeAllocationFailure();
    if (!job->m_candidate && allocationFailed)
        return Bindgen::nativeAllocationFailure();
    return job.release();
}

void Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeRunTask(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeRunTask_Arguments& args)
{
    args.job->runTask();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeTakeResult_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeTakeResult(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoCheckPrimeTakeResult_Arguments& args)
{
    return args.job->takeResult();
}

void Bindgen::Engine::releaseNodeCryptoCheckPrimeJob(CheckPrimeJobCtx* job)
{
    delete job;
}

GeneratePrimeJobCtx::GeneratePrimeJobCtx(
    int32_t size,
    bool safe,
    std::optional<std::span<const uint8_t>> add,
    std::optional<std::span<const uint8_t>> rem)
    : m_size(size)
    , m_safe(safe)
{
    if (add) {
        m_add.reset(add->data(), add->size());
        if (!m_add) {
            m_status = GeneratePrimeJobStatus::OperationFailed;
            return;
        }
        if (ncrypto::BignumPointer::GetBitCount(m_add.get()) > size) {
            m_status = GeneratePrimeJobStatus::InvalidAdd;
            return;
        }
    }

    if (rem) {
        m_rem.reset(rem->data(), rem->size());
        if (!m_rem) {
            m_status = GeneratePrimeJobStatus::OperationFailed;
            return;
        }
    }

    if (m_add && m_rem && m_add <= m_rem) {
        m_status = GeneratePrimeJobStatus::InvalidRem;
        return;
    }

    m_prime = ncrypto::BignumPointer::New();
    if (!m_prime)
        m_status = GeneratePrimeJobStatus::OperationFailed;
}

GeneratePrimeJobStatus GeneratePrimeJobCtx::status() const
{
    return m_status;
}

void GeneratePrimeJobCtx::runTask()
{
    if (m_status != GeneratePrimeJobStatus::Success)
        return;

    ERR_clear_error();
    bool succeeded = m_prime.generate({ .bits = m_size, .safe = m_safe, .add = m_add, .rem = m_rem });
    bool allocationFailed = ncrypto::takeAllocationFailure();
    if (!succeeded) {
        m_allocationFailed = allocationFailed;
        m_status = GeneratePrimeJobStatus::OperationFailed;
        return;
    }
    m_hasResult = true;
}

Bindgen::NativeAllocationResult<std::optional<WTF::Vector<uint8_t>>> GeneratePrimeJobCtx::takeResult()
{
    if (m_allocationFailed)
        return Bindgen::nativeAllocationFailure();
    if (!m_hasResult)
        return std::optional<WTF::Vector<uint8_t>> {};

    WTF::Vector<uint8_t> result;
    if (!result.tryGrow(m_prime.byteLength()))
        return Bindgen::nativeAllocationFailure();
    RELEASE_ASSERT(m_prime.encodeInto(result.mutableSpan().data()) == result.size());
    m_prime.reset();
    m_hasResult = false;
    return std::optional<WTF::Vector<uint8_t>> { WTF::move(result) };
}

Bindgen::NativeAllocationResult<GeneratePrimeJobCtx*> Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeCreate(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeCreate_Arguments& args)
{
    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(GeneratePrimeJobCtx)).getValue(storage))
        return Bindgen::nativeAllocationFailure();
    ERR_clear_error();
    auto job = std::unique_ptr<GeneratePrimeJobCtx>(new (NotNull, storage) GeneratePrimeJobCtx(args.size, args.safe, args.add, args.rem));
    bool allocationFailed = ncrypto::takeAllocationFailure();
    if (job->status() == GeneratePrimeJobStatus::OperationFailed && allocationFailed)
        return Bindgen::nativeAllocationFailure();
    return job.release();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeStatus_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeStatus(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeStatus_Arguments& args)
{
    using Return = Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeStatus_Return;
    switch (args.job->status()) {
    case GeneratePrimeJobStatus::Success:
        return Return::success;
    case GeneratePrimeJobStatus::InvalidAdd:
        return Return::invalid_add;
    case GeneratePrimeJobStatus::InvalidRem:
        return Return::invalid_rem;
    case GeneratePrimeJobStatus::OperationFailed:
        return Return::operation_failed;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeRunTask(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeRunTask_Arguments& args)
{
    args.job->runTask();
}

Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeTakeResult_Return Bindgen::Engine::bunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeTakeResult(
    const Bindgen::Engine::BunBindgenEngine_node_crypto_engine_nodeCryptoGeneratePrimeTakeResult_Arguments& args)
{
    return args.job->takeResult();
}

void Bindgen::Engine::releaseNodeCryptoGeneratePrimeJob(GeneratePrimeJobCtx* job)
{
    delete job;
}

} // namespace Bun
