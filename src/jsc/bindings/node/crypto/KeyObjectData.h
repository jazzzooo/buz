#pragma once

#include "root.h"
#include "ncrypto.h"
#include "CryptoKeyType.h"
#include <wtf/FastMalloc.h>

struct KeyObjectData : ThreadSafeRefCounted<KeyObjectData> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(KeyObjectData);

private:
    KeyObjectData(WTF::Vector<uint8_t>&& symmetricKey)
        : symmetricKey(WTF::move(symmetricKey))
    {
    }

    KeyObjectData(ncrypto::EVPKeyPointer&& asymmetricKey)
        : asymmetricKey(WTF::move(asymmetricKey))
    {
    }

public:
    ~KeyObjectData() = default;

    static RefPtr<KeyObjectData> tryCreate(WTF::Vector<uint8_t>&& symmetricKey) noexcept
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(KeyObjectData)).getValue(storage))
            return nullptr;
        return adoptRef(*new (NotNull, storage) KeyObjectData(WTF::move(symmetricKey)));
    }

    static RefPtr<KeyObjectData> tryCreate(ncrypto::EVPKeyPointer&& asymmetricKey) noexcept
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(KeyObjectData)).getValue(storage))
            return nullptr;
        return adoptRef(*new (NotNull, storage) KeyObjectData(WTF::move(asymmetricKey)));
    }

    WTF::Vector<uint8_t> symmetricKey;
    const ncrypto::EVPKeyPointer asymmetricKey;
};
