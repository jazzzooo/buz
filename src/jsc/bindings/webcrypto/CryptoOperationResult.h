#pragma once

#include "CryptoKeyPair.h"
#include "CryptoAlgorithmParameters.h"
#include "CryptoKeyFormat.h"
#include "JsonWebKey.h"
#include <variant>
#include <wtf/FastMalloc.h>

namespace WebCore {

using KeyData = std::variant<Vector<uint8_t>, JsonWebKey>;
using KeyOrKeyPair = std::variant<RefPtr<CryptoKey>, CryptoKeyPair>;

struct GeneratedCryptoKey {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(GeneratedCryptoKey);
    KeyOrKeyPair value;
};

struct ExportedCryptoKey {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(ExportedCryptoKey);
    KeyData value;
};

struct UnwrappedCryptoKey {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(UnwrappedCryptoKey);
    CryptoKeyFormat format;
    Vector<uint8_t> bytes;
    std::unique_ptr<CryptoAlgorithmParameters> parameters;
    bool extractable;
    Vector<CryptoKeyUsage> usages;
};

template<typename Result, typename Value>
Result* tryCreateCryptoResult(Value&& value)
{
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(Result)).getValue(allocation))
        return nullptr;
    return new (NotNull, allocation) Result { std::forward<Value>(value) };
}

}
