#pragma once

#include <expected>
#include <variant>

namespace Bun::Bindgen {

enum class NativeAllocationError { outOfMemory };

template<typename T>
using NativeAllocationResult = std::expected<T, NativeAllocationError>;

template<typename T, typename... Errors>
using CppResult = std::expected<T, std::variant<NativeAllocationError, Errors...>>;

inline auto nativeAllocationFailure()
{
    return std::unexpected(NativeAllocationError::outOfMemory);
}

}
