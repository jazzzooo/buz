#pragma once

#include "Enumeration.h"
#include "StringConversion.h"

namespace Bun::Bindgen {

template<typename Enum> Expected<WTF::String, WTF::UTF8ConversionError> enumerationString(Enum value)
{
    const auto name = enumerationName(value);
    return Bun::decodeUTF8ReplacingInvalidSequences(std::span {
        reinterpret_cast<const uint8_t*>(name.data()), name.size() });
}

}
