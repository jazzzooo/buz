#pragma once

#include <array>
#include <cstdint>
#include <string_view>
#include <wtf/Assertions.h>

namespace Bun::Bindgen {

template<typename Enum> struct EnumerationEntry {
    Enum value;
    std::string_view name;
};

template<typename Enum> struct EnumerationTraits;

template<typename Enum> constexpr std::string_view enumerationName(Enum value)
{
    for (const auto& entry : EnumerationTraits<Enum>::entries) {
        if (entry.value == value)
            return entry.name;
    }
    RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("binding enumeration tag is invalid");
}

}
