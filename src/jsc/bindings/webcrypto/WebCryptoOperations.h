#pragma once

#include "EventLoopTaskNoContext.h"
#include "ExceptionOr.h"
#include "JsonWebKey.h"
#include "SchemaBindings.h"

namespace WebCore {

template<typename Input>
bool copyWebCryptoJsonWebKey(const Input& input, JsonWebKey& result)
{
    if (input.kty) result.kty = *input.kty;
    if (input.use)
        result.use = *input.use;
    if (input.key_ops) {
        auto& usages = result.key_ops.emplace();
        if (!usages.tryReserveInitialCapacity(input.key_ops->size())) return false;
        for (auto usage : *input.key_ops)
            usages.unsafeAppendWithoutCapacityCheck(static_cast<CryptoKeyUsage>(usage));
    }
    if (input.alg)
        result.alg = *input.alg;
    result.ext = input.ext;
    if (input.crv)
        result.crv = *input.crv;
    if (input.x)
        result.x = *input.x;
    if (input.y)
        result.y = *input.y;
    if (input.d)
        result.d = *input.d;
    if (input.n)
        result.n = *input.n;
    if (input.e)
        result.e = *input.e;
    if (input.p)
        result.p = *input.p;
    if (input.q)
        result.q = *input.q;
    if (input.dp)
        result.dp = *input.dp;
    if (input.dq)
        result.dq = *input.dq;
    if (input.qi)
        result.qi = *input.qi;
    if (input.oth) {
        Vector<RsaOtherPrimesInfo> others;
        if (!others.tryReserveInitialCapacity(input.oth->size()))
            return false;
        for (const auto& inputOther : *input.oth) {
            RsaOtherPrimesInfo other;
            other.d = inputOther.d;
            other.r = inputOther.r;
            other.t = inputOther.t;
            others.unsafeAppendWithoutCapacityCheck(WTF::move(other));
        }
        result.oth = WTF::move(others);
    }
    if (input.k)
        result.k = *input.k;
    return true;
}

template<typename Completion>
void failWebCrypto(Completion& completion, ExceptionCode code, const String& message)
{
    using Errors = typename Completion::Errors;
    switch (code) {
    case OutOfMemoryError:
        completion.outOfMemory();
        return;
    case NotSupportedError:
        completion.fail(typename Errors::not_supported { message.isEmpty() ? "The algorithm is not supported"_s : message });
        return;
    case InvalidAccessError:
        completion.fail(typename Errors::invalid_access { message.isEmpty() ? "The requested operation is not valid for the provided key"_s : message });
        return;
    case InvalidStateError:
        completion.fail(typename Errors::invalid_state { message.isEmpty() ? "The requested operation is not valid for the current state of the provided key"_s : message });
        return;
    case SyntaxError:
        completion.fail(typename Errors::syntax { message.isEmpty() ? "A required parameter was missing or out-of-range"_s : message });
        return;
    case DataError:
        completion.fail(typename Errors::data { message.isEmpty() ? "Data provided to an operation does not meet requirements"_s : message });
        return;
    case OperationError:
        completion.fail(typename Errors::operation { message.isEmpty() ? "The operation failed for an operation-specific reason"_s : message });
        return;
    case UnknownError:
        completion.fail(typename Errors::unknown { message.isEmpty() ? "The operation failed for an unknown transient reason"_s : message });
        return;
    case TypeError:
        completion.fail(typename Errors::type { message });
        return;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

template<typename Completion, typename Result>
void completeWebCrypto(Completion& completion, Result&& result)
{
    if (result.hasException()) {
        auto failure = result.releaseException();
        failWebCrypto(completion, failure.code(), failure.message());
    } else {
        completion.resolve(result.releaseReturnValue());
    }
}

template<typename Completion, typename Operation>
void dispatchWebCrypto(Bun::Bindgen::CppCallContext& context, Completion& completion, Operation&& operation, bool background = true)
{
    if (!background) {
        completeWebCrypto(completion, operation());
        return;
    }
    auto work = [sender = completion.clone(), operation = std::forward<Operation>(operation)]() mutable {
        completeWebCrypto(sender, operation());
    };
    auto task = Bun::EventLoopFunctionTask<decltype(work)>::tryCreate(&context.globalObject, WTF::move(work));
    if (!task || !Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_concurrentCppTaskCreateAndRun(task.release()))
        completion.outOfMemory();
}

}
