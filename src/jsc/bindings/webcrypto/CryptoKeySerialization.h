#pragma once

#include "Bindgen/NativeResult.h"
#include "CryptoKey.h"
#include <optional>
#include <span>

namespace WebCore {

Bun::Bindgen::NativeAllocationResult<std::optional<Vector<uint8_t>>> serializeCryptoKey(const CryptoKey&);
Bun::Bindgen::NativeAllocationResult<RefPtr<CryptoKey>> deserializeCryptoKey(std::span<const uint8_t>);
Bun::Bindgen::NativeAllocationResult<RefPtr<CryptoKey>> deserializeLegacyCryptoKey(std::span<const uint8_t>, uint32_t maximumVersion);

}
